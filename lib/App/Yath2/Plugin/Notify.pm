package App::Yath2::Plugin::Notify;
use v5.38;

our $VERSION = '2.000000';

use Test2::Harness2::Util::JSON qw/encode_json/;
use Test2::Harness2::Util qw/mod2file/;

use App::Yath2::TestFile();

use Sys::Hostname qw/hostname/;

use Carp qw/croak confess/;

use Getopt::Yath;

use parent 'App::Yath2::Plugin';
use Test2::Harness2::Util::HashBase qw/-final -tries -problems -problem_cids +text_mod +text_mod_handles_events +text_mod_fail/;

# Notifications only apply to commands which build a run.
sub applicable ($opt, $options, $settings) {
    return $options && $options->option_groups->{run} ? 1 : 0;
}

option_group {group => 'notify', prefix => 'notify', category => "Notification Options", applicable => \&applicable} => sub {
    option slack => (
        type => 'List',
        description => "Send results to a slack channel and/or user",
        long_examples  => [" '#foo'", " '\@bar'"],
    );

    option slack_fail => (
        type => 'List',
        description => "Send failing results to a slack channel and/or user",
        long_examples => [" '#foo'", " '\@bar'"],
    );

    option slack_url => (
        type => 'Scalar',
        description => "Specify an API endpoint for slack webhook integrations",
        long_examples  => [" https://hooks.slack.com/..."],
    );

    option slack_owner => (
        type => 'Bool',
        description => "Send slack notifications to the slack channels/users listed in test meta-data when tests fail.",
        default => 0,
    );

    option no_batch_slack => (
        type => 'Bool',
        default => 0,
        description => 'Usually owner failures are sent as a single batch at the end of testing. Toggle this to send failures as they happen.',
    );

    option email_from => (
        type          => 'Scalar',
        long_examples => [' foo@example.com'],
        description   => "If any email is sent, this is who it will be from",
        default       => sub {
            my $user = getlogin() || scalar(getpwuid($<)) || $ENV{USER} || 'unknown';
            my $host = hostname() || 'unknown';
            return "${user}\@${host}";
        },
    );

    option email => (
        type => 'List',
        long_examples => [' foo@example.com'],
        description => "Email the test results to the specified email address(es)",
    );

    option email_fail => (
        type => 'List',
        long_examples => [' foo@example.com'],
        description => "Email failing results to the specified email address(es)",
    );

    option email_owner => (
        type => 'Bool',
        description => 'Email the owner of broken tests files upon failure. Add `# HARNESS-META-OWNER foo@example.com` to the top of a test file to give it an owner',
        default => 0,
    );

    option no_batch_email => (
        type => 'Bool',
        default => 0,
        description => 'Usually owner failures are sent as a single batch at the end of testing. Toggle this to send failures as they happen.',
    );

    option text => (
        type => 'Scalar',
        alt => ['message', 'msg'],
        description => "Add a custom text snippet to email/slack notifications",
    );

    option text_module => (
        type => 'Scalar',
        alt => ['message-module'],
        description => "Use the specified module to generate messages for emails and/or slack.",
    );

    option_post_process 0 => sub ($options, $state) {
        my $settings = $state->{settings};

        # Getopt::Yath does not track set-by-cli source. The owner flags both
        # default to 0 and can only be turned ON via the CLI (Bool), so
        # "default owner unless the user set it" is equivalent to "default
        # owner unless it is already truthy".

        # Should we use email?
        if (@{$settings->notify->email} || $settings->notify->email_owner) {
            $settings->notify->option(email_owner => 1) unless $settings->notify->email_owner;

            # Do we have Email::Stuffer?
            my $ok = eval { require Email::Stuffer; 1 };
            die "Cannot use --email-owner without Email::Stuffer, which is not installed.\n" unless $ok;

            push @{$settings->harness->plugins} => __PACKAGE__->new() unless grep { $_->isa(__PACKAGE__) } @{$settings->harness->plugins};
        }

        my $use_slack = grep { $settings->notify->$_ } qw/slack_url slack_owner/;
        $use_slack ||= grep { @{$settings->notify->$_} } qw/slack slack_fail/;
        if ($use_slack) {
            die "slack url must be provided in order to use slack" unless $settings->notify->slack_url;

            my $ok = eval { require HTTP::Tiny; 1 };
            die "Cannot use slack without HTTP::Tiny which is not installed.\n" unless $ok;

            die "HTTP::Tiny reports that it does not support SSL, cannot use slack without ssl."
                unless HTTP::Tiny::can_ssl();

            $settings->notify->option(slack_owner => 1) unless $settings->notify->slack_owner;

            push @{$settings->harness->plugins} => __PACKAGE__->new() unless grep { $_->isa(__PACKAGE__) } @{$settings->harness->plugins};
        }
    };
};

sub text_mod {
    my $self = shift;
    my ($settings) = @_;

    croak 'settings is a required argument' unless $settings;

    return $self->{+TEXT_MOD} if exists $self->{+TEXT_MOD};

    if (my $tm = $settings->notify->text_module) {
        my $file = mod2file($tm);
        if (eval { require $file; 1 }) {
            my $inst = $tm->can('new') ? $tm->new() : $tm;
            $self->{+TEXT_MOD_HANDLES_EVENTS} = $inst->can('handle_event') ? 1 : 0;
            return $self->{+TEXT_MOD} = $inst;
        }
        else {
            my $err = $@;
            warn "Cannot use module '$tm' for notification text generation: $err";
            chomp($self->{+TEXT_MOD_FAIL} = $err);
        }
    }

    $self->{+TEXT_MOD_HANDLES_EVENTS} = 0;
    return $self->{+TEXT_MOD} = undef;
}

sub handle_event {
    my $self = shift;
    my ($e, $settings) = @_;

    my $f = $e->facet_data;

    $self->record_problem($f);

    my $tm = $self->text_mod($settings);
    if ($tm && $self->{+TEXT_MOD_HANDLES_EVENTS}) {
        $tm->handle_event($e, $f, settings => $settings, notify => $self);
    }

    return $self->handle_job_end($e, $f, $settings) if $f->{harness_job_end};
    return $self->handle_final($e, $f, $settings) if $f->{harness_final};

    return;
}

sub record_problem {
    my $self = shift;
    my ($f) = @_;

    return unless $self->has_fail_or_error($f);

    my $job_id  = $f->{harness}->{job_id};
    my $job_try = $f->{harness}->{job_try} // 0;

    push @{$self->{+PROBLEMS}->{$job_id}->{$job_try}} => $self->prune_subtests($f);
}

sub has_fail_or_error {
    my $self = shift;
    my ($f, %params) = @_;

    return 0 if $f->{trace}->{nested} && !$params{allow_nested};
    return 0 if $f->{amnesty} && @{$f->{amnesty}};

    my $out = 0;

    my $cid = $f->{trace}->{cid};
    $out = 1 if $cid && $self->{+PROBLEM_CIDS}->{$cid} && $f->{info} && @{$f->{info}};
    $out = 1 if $f->{errors} && @{$f->{errors}};
    $out = 1 if $f->{assert} && !$f->{assert}->{pass};

    $self->{+PROBLEM_CIDS}->{$cid} = 1 if $cid && $out;

    return $out;
}

sub prune_subtests {
    my $self = shift;
    my ($f) = @_;

    my $p = $f->{parent}   // return $f;
    my $c = $p->{children} // return $f;

    return $f unless @$c;

    my $out = {};
    $out->{$_} = $f->{$_} for grep { $f->{$_} } qw/assert about trace errors info harness control/;
    $out->{parent} = {%$p, children => [map { $self->prune_subtests($_) } grep { $self->has_fail_or_error($_, allow_nested => 1) } @$c]};

    return $out;
}

sub handle_final {
    my $self = shift;
    my ($e, $f, $settings) = @_;

    $self->{+FINAL} = $e;
}

sub handle_job_end {
    my $self = shift;
    my ($e, $f, $settings) = @_;

    return unless $f->{harness_job_end}->{fail};

    my $job_id = $f->{harness}->{job_id};

    if ($f->{harness_job_end}->{retry}) {
        $self->{+TRIES}->{$job_id}++;
        return;
    }

    my @args = ($e, $f, $self->{+TRIES}->{$job_id}, $settings);

    $self->_send_job_notification('slack', @args);
    $self->_send_job_notification('email', @args);
}

# Per-service knobs that drive the shared slack/email builders. Every
# difference between the slack and email notification paths lives here so the
# _send_*/_gen_* helpers below stay service-agnostic.
sub _service_spec ($self, $service) {
    return {
        no_batch   => 'no_batch_slack',
        list       => 'slack',
        fail_list  => 'slack_fail',
        owner_flag => 'slack_owner',
        meta_key   => 'slack',
        links_fmt  => sub { map {"> <$_|$_>"} @_ },
        subject    => undef,
        send       => sub ($self, $settings, $subject, $text, @to) { $self->_send_slack($text, $settings, @to) },
    } if $service eq 'slack';

    return {
        no_batch   => 'no_batch_email',
        list       => 'email',
        fail_list  => 'email_fail',
        owner_flag => 'email_owner',
        meta_key   => 'owner',
        links_fmt  => sub { @_ },
        send       => sub ($self, $settings, $subject, $text, @to) { $self->_send_email($subject, $text, $settings, @to) },
    } if $service eq 'email';

    croak "Unknown notification service '$service'";
}

sub _send_job_notification ($self, $service, $e, $f, $tries, $settings) {
    my $spec = $self->_service_spec($service);

    my $no_batch = $spec->{no_batch};
    return unless $settings->notify->$no_batch;

    my $tf = App::Yath2::TestFile->new(file => $f->{harness_job_end}->{abs_file});

    my $owner_flag = $spec->{owner_flag};
    my $fail_list  = $spec->{fail_list};

    my @to;
    push @to => $tf->meta($spec->{meta_key}) if $settings->notify->$owner_flag;
    push @to => @{$settings->notify->$fail_list};

    return unless @to;

    my $text = $self->gen_text(scope => 'job', service => $service, settings => $settings, file => $tf, tries => $tries);
    my $subject = $service eq 'email' ? "Failed test on " . hostname() . ": '" . $tf->relative . "'." : undef;

    $spec->{send}->($self, $settings, $subject, $text, @to);
}

# Shared body for gen_slack_job_text / gen_email_job_text. The two named
# delegators below differ only in how run links are formatted (links_fmt).
sub _gen_job_text {
    my $self = shift;
    my %params = @_;

    my $settings  = $params{settings}  // croak "'settings' is required";
    my $tf        = $params{file}      // croak "'file' is required";
    my $tries     = $params{tries}     // 0;
    my $links_fmt = $params{links_fmt} // sub { @_ };

    my $host = hostname();
    my $file = $tf->relative;

    return join "\n\n" => grep { $_ }
        $settings->notify->text,
        "Failed test on $host: '$file'.",
        $tries ? ("Test was run " . (1 + $tries) . " time(s).") : (),
        join "\n" => $links_fmt->(@{$settings->run->links});
}

sub gen_slack_job_text {
    my $self = shift;
    return $self->_gen_job_text(@_, links_fmt => sub { map {"> <$_|$_>"} @_ });
}

sub gen_email_job_text {
    my $self = shift;
    return $self->_gen_job_text(@_, links_fmt => sub { @_ });
}

sub _send_slack {
    my $self = shift;
    my ($text, $settings, @to) = @_;

    require HTTP::Tiny;
    my $ht = HTTP::Tiny->new();

    for my $dest (@to) {
        my $r = $ht->post(
            $settings->notify->slack_url,
            {
                headers => {'content-type' => 'application/json'},
                content => encode_json({channel => $dest, text => $text}),
            },
        );
        warn "Failed to send slack message to '$dest'" unless $r->{success};
    }
}

sub _send_email {
    my $self = shift;
    my ($subject, $text, $settings, @to) = @_;

    my $mail = Email::Stuffer->to(@to);
    $mail->from($settings->notify->email_from);
    $mail->subject($subject);

    my $rtype = ref($text) // '';

    if (!$rtype) {
        $mail->text_body($text);
    }
    elsif ($rtype eq 'HASH') {
        $mail->text_body($text->{text}) if $text->{text};
        $mail->html_body($text->{html}) if $text->{html};
    }
    else {
        warn "Invalid text type: '$rtype'";
    }

    eval { $mail->send_or_die; 1 } or warn $@;
}

sub finish {
    my $self = shift;
    my %params = @_;
    my $settings = $params{settings};

    my $e = $self->{+FINAL} or return;
    my $f = $e->facet_data or return;
    my $final = $f->{harness_final} or return;

    $self->_send_run_notification('slack', $final, $settings);
    $self->_send_run_notification('email', $final, $settings);
}

sub _send_run_notification ($self, $service, $final, $settings) {
    my $spec = $self->_service_spec($service);

    my $no_batch = $spec->{no_batch};
    return if $settings->notify->$no_batch;

    my $list       = $spec->{list};
    my $fail_list  = $spec->{fail_list};
    my $owner_flag = $spec->{owner_flag};

    my @to = @{$settings->notify->$list};
    push @to => @{$settings->notify->$fail_list} unless $final->{pass};

    my $files = "";
    if ($final->{failed}) {
        for my $set (@{$final->{failed}}) {
            my $file = $set->[1];

            $files = $files ? "$files\n$file" : $file;

            next unless $settings->notify->$owner_flag;
            my $tf = App::Yath2::TestFile->new(file => $file);
            push @to => $tf->meta($spec->{meta_key});
        }
    }

    return unless @to;

    my $subject = $service eq 'email'
        ? $self->gen_text(scope => 'run', service => 'email_subject', settings => $settings, final => $final, files => $files)
        : undef;

    my $text = $self->gen_text(
        scope    => 'run',
        service  => $service,
        settings => $settings,
        final    => $final,
        files    => $files,
        ($subject ? (subject => $subject) : ()),
    );

    $spec->{send}->($self, $settings, $subject, $text, @to);
}

# Shared body for gen_slack_run_text / gen_email_run_text. Differs only in the
# link formatting (links_fmt) and the second line (email passes a subject;
# slack falls back to the identical pass/fail string).
sub _gen_run_text {
    my $self = shift;
    my %params = @_;

    my $settings  = $params{settings}  // croak "'settings' is required";
    my $final     = $params{final}     // croak "'final' is required";
    my $files     = $params{files}     // '';
    my $links_fmt = $params{links_fmt} // sub { @_ };

    my $host = hostname();

    return join "\n\n" => grep { $_ } (
        $settings->notify->text,
        ($params{subject} // ($final->{pass} ? "Tests passed on $host" : "Tests failed on $host")),
        ($files ? $files : ()),
        join("\n" => $links_fmt->(@{$settings->run->links})),
    );
}

sub gen_slack_run_text {
    my $self = shift;
    return $self->_gen_run_text(@_, links_fmt => sub { map {"> <$_|$_>"} @_ });
}

sub gen_email_run_text {
    my $self = shift;
    my %params = @_;

    my $subject = $params{subject} // $self->gen_text(%params, service => 'email_subject');

    return $self->_gen_run_text(%params, subject => $subject, links_fmt => sub { @_ });
}

sub gen_email_subject_run_text {
    my $self = shift;
    my %params = @_;

    my $final = $params{final} // croak "'final' is required";
    my $host  = hostname();

    return $final->{pass} ? "Tests passed on $host" : "Tests failed on $host";
}

sub gen_text {
    my $self   = shift;
    my %params = @_;

    my $scope    = $params{scope}    or croak "'scope' is required";
    my $service  = $params{service}  or croak "'service' is required";
    my $settings = $params{settings} or croak "'settings' is required";

    my $meth = "gen_${service}_${scope}_text";

    if (my $tm = $self->text_mod($settings)) {
        return $tm->$meth(%params, notify => $self)
            if $tm->can($meth);
    }

    if ($self->can($meth)) {
        my $text = $self->$meth(%params);

        my $mod = $settings->notify->text_module;
        $text = <<"        EOT" if $self->{+TEXT_MOD_FAIL} && $service !~ m/subject/i;
*******************************************************************************
There was an error loading the text generation module '$mod'.
Because of this error the default notification text has been used.

The error encountered was:
$self->{+TEXT_MOD_FAIL}
*******************************************************************************

$text
        EOT

        return $text;
    }

    confess "No notification text method '$meth'";
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Plugin::Notify - Plugin to send email and/or slack notifications

=head1 DESCRIPTION

This plugin is used for sending email and/or slack notifications from yath.

=head1 SYNOPSIS

=head2 IN A TEST

    #!/usr/bin/perl
    use Test2::V0;
    # HARNESS-META owner author@example.com
    # HARNESS-META slack #slack_channel
    # HARNESS-META slack #slack_user

You can use the C<# HARNESS-META owner EMAIL_ADDRESS> to specify an "owner"
email address. You can use the C<# HARNESS-META slack USER/CHANNEL> to specify
a slack user or channel that owns the test.

=head2 RUNNING WITH NOTIFICATIONS ENABLED

    $ yath test -pNotify ...

Also of note, most of the time you can just specify the notification options
you want and the plugin will load as needed as long as C<--no-scan-plugins> was
not specified.

=head3 EMAIL

    $ yath test --notify-email-owner --notify-email-from user@example.com --notify-email-fail fixer@example.com

=head3 SLACK

A slack hooks url is always needed for slack to work.

    $ yath test --notify-slack-url https://hooks.slack.com/... --notify-slack-fail '#foo' --notify-slack-owner

=head1 PROVIDED OPTIONS

=head3 Notification Options

=over 4

=item --notify-email foo@example.com

=item --no-notify-email

Email the test results to the specified email address(es)

Note: Can be specified multiple times


=item --notify-email-fail foo@example.com

=item --no-notify-email-fail

Email failing results to the specified email address(es)

Note: Can be specified multiple times


=item --notify-email-from foo@example.com

=item --no-notify-email-from

If any email is sent, this is who it will be from


=item --notify-email-owner

=item --no-notify-email-owner

Email the owner of broken tests files upon failure. Add `# HARNESS-META-OWNER foo@example.com` to the top of a test file to give it an owner


=item --notify-no-batch-email

=item --no-notify-no-batch-email

Usually owner failures are sent as a single batch at the end of testing. Toggle this to send failures as they happen.


=item --notify-no-batch-slack

=item --no-notify-no-batch-slack

Usually owner failures are sent as a single batch at the end of testing. Toggle this to send failures as they happen.


=item --notify-slack '#foo'

=item --notify-slack '@bar'

=item --no-notify-slack

Send results to a slack channel and/or user

Note: Can be specified multiple times


=item --notify-slack-fail '#foo'

=item --notify-slack-fail '@bar'

=item --no-notify-slack-fail

Send failing results to a slack channel and/or user

Note: Can be specified multiple times


=item --notify-slack-owner

=item --no-notify-slack-owner

Send slack notifications to the slack channels/users listed in test meta-data when tests fail.


=item --notify-slack-url https://hooks.slack.com/...

=item --no-notify-slack-url

Specify an API endpoint for slack webhook integrations


=item --notify-msg ARG

=item --notify-msg=ARG

=item --notify-text ARG

=item --notify-text=ARG

=item --notify-message ARG

=item --notify-message=ARG

=item --no-notify-text

Add a custom text snippet to email/slack notifications


=item --notify-text-module ARG

=item --notify-text-module=ARG

=item --notify-message-module ARG

=item --notify-message-module=ARG

=item --no-notify-text-module

Use the specified module to generate messages for emails and/or slack.


=back


=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
