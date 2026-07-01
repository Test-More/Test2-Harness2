package App::Yath2::Plugin::YathUI;
use v5.38;

our $VERSION = '2.000000';

use File::Spec;
use Test2::Harness2::Util qw/read_file mod2file looks_like_uuid/;
use Test2::Harness2::Util::JSON qw/decode_json/;

use Getopt::Yath;
use parent 'App::Yath2::Plugin';

sub can_log ($opt, $options, $settings) {
    return $options && $options->option_groups->{jsonl} ? 1 : 0;
}

sub can_finder ($opt, $options, $settings) {
    return $options && $options->option_groups->{finder} ? 1 : 0;
}

option_group {group => 'yathui', prefix => 'yathui', category => "YathUI Options"} => sub {
    option url => (
        type => 'Scalar',
        alt => ['uri'],
        description => "Yath-UI url",
        long_examples  => [" http://my-yath-ui.com/..."],
    );

    option api_key => (
        type => 'Scalar',
        description => "Yath-UI API key. This is not necessary if your Yath-UI instance is set to single-user"
    );

    option project => (
        type => 'Scalar',
        description => "The Yath-UI project for your test results",
    );

    option mode => (
        type => 'Scalar',
        default => 'qvfd',
        description => "Set the upload mode (default 'qvfd')",
        long_examples => [
            ' summary',
            ' qvf',
            ' qvfd',
            ' complete',
        ],
    );

    option retry => (
        type => 'Count',
        description => "How many times to try an operation before giving up",
        initialize => 0,
    );

    option grace => (
        type => 'Bool',
        description => "If yath cannot connect to yath-ui it normally throws an error, use this to make it fail gracefully. You get a warning, but things keep going.",
        default => 0,
    );

    option durations => (
        type => 'Bool',
        description => "Poll duration data from Yath-UI to help order tests efficiently",
        default => 0,
        applicable => \&can_finder,
    );

    option coverage => (
        type => 'Bool',
        description => "Poll coverage data from Yath-UI to determine what tests should be run for changed files",
        default => 0,
        applicable => \&can_finder,
    );

#    TODO
#    option median_durations => (
#        type => 'Bool',
#        description => "Get median duration data",
#        default => 0,
#    );

    option medium_duration => (
        type => 'Scalar',
        description => "Minimum duration length (seconds) before a test goes from SHORT to MEDIUM",
        long_examples => [' 5'],
        default => 5,
    );

    option long_duration => (
        type => 'Scalar',
        description => "Minimum duration length (seconds) before a test goes from MEDIUM to LONG",
        long_examples => [' 10'],
        default => 10,
    );

    option upload => (
        type => 'Bool',
        description => "Upload the log to Yath-UI",
        default => 0,
        applicable => \&can_log,
    );

    option_post_process -1 => sub ($options, $state) {
        my $settings = $state->{settings};

        my $has_finder = $options && $options->option_groups->{finder};
        my $has_logger = $options && $options->option_groups->{jsonl};

        my $has_durations = $has_finder && $settings->yathui->durations;
        my $has_upload    = $has_logger && $settings->yathui->upload;
        my $has_coverage  = $has_finder && $settings->yathui->coverage;

        return unless $has_durations || $has_upload || $has_coverage;

        my $url     = $settings->yathui->url     or die "'--yathui-url URL' is required to use durations, coverage, or upload a log";
        my $project = $settings->yathui->project or die "'--yathui-project NAME' is required to use durations, coverage, or upload a log";
        my $grace   = $settings->yathui->grace;

        $url =~ s{/+$}{}g;

        # Cross-group writes: use create_option (set-or-create, matching the
        # old Settings 'field' semantics) since the target group/option may not
        # have been initialized by another module.
        #
        # Force-enable the jsonl renderer (bzip2, the format YathUI uploads). This
        # post_process runs at weight -1, BEFORE the jsonl group's own weight-101
        # resolver, so we only set the enable/compression FLAGS here -- the jsonl
        # resolver then resolves the file path and injects the renderer into the
        # renderer list (replacing the old logging->log force-set).
        if ($has_upload) {
            my $jsonl = $settings->group('jsonl', 1);
            $jsonl->create_option(enabled => 1);
            $jsonl->create_option(bzip2   => 1);
        }

        if ($has_coverage) {
            my $curl = join '/' => ($url, 'coverage', $project);
            $settings->group('cover', 1)->create_option(($grace ? 'maybe_from' : 'from'), $curl);
        }

        if ($has_durations) {
            my $med  = $settings->yathui->medium_duration;
            my $long = $settings->yathui->long_duration;

            my $durl = join '/' => ($url, 'durations', $project, $med, $long);
            $settings->finder->create_option(($grace ? 'maybe_durations' : 'durations'), $durl);
        }

        return;
    };
};

sub grab_rerun {
    my $this = shift;
    my ($rerun, %params) = @_;

    return (0) if $rerun =~ m/\.jsonl(\.gz|\.bz2)?/;

    my $settings  = $params{settings};
    my $mode_hash = $params{mode_hash};

    my $path;
    if ($rerun eq '1') {
        my $project = $settings->yathui->project or return (0);
        my $user = ($settings->yathui->check_option('user') ? $settings->yathui->user : undef) // $ENV{USER};

        $path = "$project/$user";

        print "Re-run requested with no paremeters, ${ \__PACKAGE__ } querying YathUI (web request) for last run matching $path...\n";

        # API Qwerk :-/
        $path .= '/0';
    }
    elsif (looks_like_uuid($rerun)) {
        $path = "$rerun";
        print "Re-run requested with UUID, ${ \__PACKAGE__ } querying YathUI (web request) for matching run, or latest run from project or user matching the UUID\n";
    }
    else {
        return (0);
    }

    $path = "rerun/$path";

    my ($ok, $res, $data) = $this->_request($settings, $path, {json => 1});

    if (!$ok) {
        print "Error getting a re-run data from yathui: $data...\n";
        return (1);
    }

    return (1, $data);
}

sub _request {
    my $this = shift;
    my ($settings, $path, $payload) = @_;

    my $url = $settings->yathui->url;
    $url =~ s{/+$}{}g;
    $url = join "/" => ($url, $path);

    my %fields;

    for my $field (qw/project api_key mode/) {
        my $val = $settings->yathui->option($field) or next;
        $fields{$field} = $val;
    }

    require HTTP::Tiny;
    eval { require HTTP::Tiny::Multipart; 1 } or die "To use --yathui-* you must install HTTP::Tiny::Multipart.\n";

    my $res;
    for (0 .. $settings->yathui->retry) {
        my $http = HTTP::Tiny->new;
        $res  = $http->post_multipart(
            $url => {
                headers => {'Content-Type' => 'application/json'},
                %fields,
                %$payload,
            },
        );

        next unless $res;
        last if $res->{status} eq '200';
    }

    my ($ok, $msg);
    if ($res && $res->{status} eq '200') {
        my $data;
        $ok = eval { $data = decode_json($res->{content}); 1 };
        if ($ok) {
            return (1, $res, $data);
        }
        else {
            $msg = $@;
        }
    }
    else {
        if ($res) {
            $msg = "Server responded with " . $res->{status} . ":\n" . ($res->{content} // 'NO CONTENT');
        }
        else {
            $msg = "Failed to upload yathui log, no response object";
        }
    }

    return (0, $res, $msg);
}

sub finish {
    my $this = shift;
    my %params = @_;

    my $settings = $params{settings};

    return unless $settings->yathui->upload;

    my $log_file = $settings->jsonl->file;
    my ($filename) = reverse File::Spec->splitpath($log_file);

    my ($ok, $res, $data) = $this->_request(
        $settings,
        'upload', {
            log_file => {
                filename     => $filename,
                content      => read_file($log_file, no_decompress => 1),
                content_type => 'application/x-bzip2',
            },

            action => 'Upload Log',
            json   => 1,
        }
    );

    die "Error connecting to YathUI: $data\n"
        unless $ok;

    my $msg;
    if ($data->{errors} && @{$data->{errors}}) {
        $ok  = 0;
        $msg = join "\n" => (@{$data->{errors}});
    }
    elsif ($data->{messages}) {
        $ok = 1;

        my $url = $settings->yathui->url;
        $url =~ s{/+$}{}g;

        $msg = join "\n" => (
            @{$data->{messages}},
            $data->{run_id} ? ("YathUI run url: " . join '/' => ($url, 'run', $data->{run_id})) : (),
        );
    }
    else {
        $ok  = 0;
        $msg = "No messages recieved";
    }

    chomp($msg);
    $msg = "YathUI Upload: $msg";
    if ($ok) {
        print "\n$msg\n";
    }
    else {
        if ($settings->yathui->grace) {
            warn $msg;
        }
        else {
            die $msg;
        }
    }

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Plugin::YathUI - Plugin to interact with a YathUI server

=head1 DESCRIPTION

If you have a Yath-UI L<Test2::Harness2::UI> server, you can use this module to
have yath automatically upload logs or retrieve durations data

=head1 PROVIDED OPTIONS

=head3 YathUI Options

=over 4

=item --yathui-api-key ARG

=item --yathui-api-key=ARG

=item --no-yathui-api-key

Yath-UI API key. This is not necessary if your Yath-UI instance is set to single-user


=item --yathui-coverage

=item --no-yathui-coverage

Poll coverage data from Yath-UI to determine what tests should be run for changed files


=item --yathui-durations

=item --no-yathui-durations

Poll duration data from Yath-UI to help order tests efficiently


=item --yathui-grace

=item --no-yathui-grace

If yath cannot connect to yath-ui it normally throws an error, use this to make it fail gracefully. You get a warning, but things keep going.


=item --yathui-long-duration 10

=item --no-yathui-long-duration

Minimum duration length (seconds) before a test goes from MEDIUM to LONG


=item --yathui-medium-duration 5

=item --no-yathui-medium-duration

Minimum duration length (seconds) before a test goes from SHORT to MEDIUM


=item --yathui-mode qvf

=item --yathui-mode qvfd

=item --yathui-mode summary

=item --yathui-mode complete

=item --no-yathui-mode

Set the upload mode (default 'qvfd')


=item --yathui-project ARG

=item --yathui-project=ARG

=item --no-yathui-project

The Yath-UI project for your test results


=item --yathui-retry

=item --yathui-retry=COUNT

=item --no-yathui-retry

How many times to try an operation before giving up

Note: Can be specified multiple times, counter bumps each time it is used.


=item --yathui-upload

=item --no-yathui-upload

Upload the log to Yath-UI


=item --yathui-url http://my-yath-ui.com/...

=item --yathui-uri http://my-yath-ui.com/...

=item --no-yathui-url

Yath-UI url


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
