package App::Yath2::Options::Debug;
use v5.38;

our $VERSION = '2.000000';

use Test2::Harness2::Util::JSON qw/encode_pretty_json/;
use Test2::Util::Table qw/table/;
use Test2::Harness2::Util qw/find_libraries mod2file clean_path/;

use Errno qw/EINTR/;
use Time::HiRes ();

use Getopt::Yath;

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::Debug - Debug options for Yath

=head1 DESCRIPTION

This is where debug related command line options live.

=head1 PROVIDED OPTIONS

=head3 Help and Debugging

=over 4

=item -d

=item --dummy

=item --no-dummy

Dummy run, do not actually execute anything

Can also be set with the following environment variables: C<T2_HARNESS_DUMMY>

The following environment variables will be cleared after arguments are processed: C<T2_HARNESS_DUMMY>


=item -h

=item -h=Group

=item --help

=item --help=Group

=item --no-help

exit after showing help information


=item -i

=item --interactive

=item --no-interactive

Use interactive mode, 1 test at a time, stdin forwarded to it


=item -k

=item --keep-dir

=item --keep-dirs

=item --no-keep-dirs

Do not delete directories when done. This is useful if you want to inspect the directories used for various commands.


=item --procname-prefix ARG

=item --procname-prefix=ARG

=item --no-procname-prefix

Add a prefix to all proc names (as seen by ps).


=item --show-opts

=item --show-opts=group

=item --no-show-opts

Exit after showing what yath thinks your options mean


=item --summary

=item --summary=/path/to/summary.json

=item --no-summary

Write out a summary json file, if no path is provided 'summary.json' will be used. The .json extension is added automatically if omitted.


=item -V

=item --version

=item --no-version

Exit after showing a helpful usage message


=back


=cut

option_group {group => 'debug', category => 'Help and Debugging'} => sub {
    option dummy => (
        type           => 'Bool',
        short          => 'd',
        description    => 'Dummy run, do not actually execute anything',
        from_env_vars  => [qw/T2_HARNESS_DUMMY/],
        clear_env_vars => [qw/T2_HARNESS_DUMMY/],
        default        => 0,
    );

    option procname_prefix => (
        type        => 'Scalar',
        default     => '',
        description => 'Add a prefix to all proc names (as seen by ps).',
    );

    option keep_dirs => (
        type        => 'Bool',
        short       => 'k',
        alt         => ['keep-dir'],
        description => 'Do not delete directories when done. This is useful if you want to inspect the directories used for various commands.',
        default     => 0,
    );

    option 'show-opts' => (
        type           => 'Auto',
        autofill       => 1,
        description    => 'Exit after showing what yath thinks your options mean',
        short_examples => ['', '=group'],
        long_examples  => ['', '=group'],
    );

    option version => (
        type        => 'Bool',
        short       => 'V',
        description => "Exit after showing a helpful usage message",
    );

    option help => (
        type           => 'Auto',
        autofill       => 1,
        short          => 'h',
        description    => "exit after showing help information",
        short_examples => ['', '=Group'],
        long_examples  => ['', '=Group'],
    );

    option interactive => (
        type        => 'Bool',
        short       => 'i',
        description => 'Use interactive mode, 1 test at a time, stdin forwarded to it',
    );

    option summary => (
        type          => 'Auto',
        autofill      => sub { clean_path('summary.json') },
        description   => "Write out a summary json file, if no path is provided 'summary.json' will be used. The .json extension is added automatically if omitted.",
        long_examples => ['', '=/path/to/summary.json'],
        normalize     => \&normalize_summary,
        applicable    => sub ($opt, $options, $settings) {
            return 1 if $options && $options->option_groups->{run};
            return 0;
        },
    );
};

option_post_process 99999 => \&_post_process_show_opts;
option_post_process 99998 => \&_post_process_interactive;
option_post_process 0     => \&_post_process_version;
option_post_process 0     => \&_post_process_help;

sub normalize_summary ($val) {
    return clean_path('summary.json') if !defined($val) || $val eq '1';

    $val =~ s/\.json$//g;
    $val .= '.json';

    return clean_path($val);
}

sub _print_command_banner ($settings) {
    # Guard command access defensively — wired in a later task
    return unless $settings->check_group('harness') && $settings->harness->check_option('command');
    my $cmd_class = $settings->harness->command;
    print "\nCommand selected: " . $cmd_class->name . "  (" . $cmd_class . ")\n" if $cmd_class;
}

sub _post_process_help ($options, $state) {
    my $settings = $state->{settings};

    return unless $settings->debug->help;

    # Defer to the help command when it is the resolved command. This lets
    # `yath --help` (and `yath -h`) with no command word fall through to
    # help->run(), which prints the command table. When a real command was
    # resolved (e.g. `yath --help test`) we do NOT defer: we print that
    # command's help here and exit.
    if ($settings->check_group('harness') && $settings->harness->check_option('command')) {
        my $cmd_class = $settings->harness->command;
        return if $cmd_class && $cmd_class->isa('App::Yath2::Command::help');
    }

    my $group = $settings->debug->help;

    _print_command_banner($settings);

    my $help = $options->docs('cli', settings => $settings, ($group && $group ne '1' ? (group => $group) : ()));

    my $ok  = eval { require IO::Pager; 1 };
    my $err = $@;
    if ($ok) {
        local $SIG{PIPE} = sub { };
        my $pager = IO::Pager->new(*STDOUT);
        $pager->print($help);
    }
    else {
        print $help;
    }

    exit 0;
}

sub _post_process_show_opts ($options, $state) {
    my $settings = $state->{settings};

    return unless $settings->debug->show_opts;

    _print_command_banner($settings);

    my $remains = $state->{remains} // [];
    print "\nCommand args: " . join(', ' => @$remains) . "\n" if @$remains;

    my $group = $settings->debug->show_opts;
    my $out =
        $group eq '1'
        ? encode_pretty_json($settings)
        : encode_pretty_json($settings->check_group($group) ? $settings->$group : "!! Invalid Group '$group' !!");

    print "\nCurrent command line and config options result in these settings:\n";
    print "$out\n";

    exit 0;
}

my $RAN = 0;

sub _post_process_interactive ($options, $state) {
    return if $RAN++;

    my $settings = $state->{settings};

    return unless $settings->debug->interactive;

    my ($fifo);
    if ($settings->check_group('workspace')) {
        my $dir = $settings->workspace->workdir;
        $fifo = "$dir/fifo-$$";
    }
    else {
        require File::Temp;
        my ($fh, $tmpfile) = File::Temp::tempfile("YATH-FIFO-$$-XXXXXX", TMPDIR => 1);
        close($fh);
        unlink($tmpfile);
        $fifo = $tmpfile;
    }

    ${$settings->debug->option_ref('fifo', 1)} = $fifo;

    if ($settings->check_group('display')) {
        my $display = $settings->display;
        $display->create_option(quiet   => 0) if $display->check_option('quiet');
        $display->create_option(verbose => 1) if $display->check_option('verbose') && !$display->verbose;
    }

    if ($settings->check_group('formatter')) {
        my $formatter = $settings->formatter;
        $formatter->create_option(qvf => 0) if $formatter->check_option('qvf');
    }

    if ($settings->check_group('run')) {
        $settings->run->create_option(env_vars => {}) unless $settings->run->check_option('env_vars');
        $settings->run->env_vars->{YATH_INTERACTIVE} = $fifo;
        $ENV{YATH_INTERACTIVE} = $fifo;
    }

    my $pid = fork() // die "Could not fork: $!";
    if ($pid) {
        require Scope::Guard;
        require POSIX;
        POSIX::mkfifo($fifo, 0700) or die "Failed to make fifo ($fifo): $!";
        my $fh;

        my $cleanup = sub {
            close($fh)    if $fh;
            unlink($fifo) if -e $fifo;
        };

        my $old_int_handler  = $SIG{INT};
        my $old_term_handler = $SIG{TERM};

        $SIG{INT}  = sub { $cleanup->('INT');  $old_int_handler->()  if ref $old_int_handler;  exit 1; };
        $SIG{TERM} = sub { $cleanup->('TERM'); $old_term_handler->() if ref $old_term_handler; exit 1; };
        $SIG{PIPE} = sub { exit 1 };

        $SIG{CHLD} = sub {
            local $?;
            my $res  = waitpid($pid, 0);
            my $exit = ($? >> 8);

            close($fh)    if $fh;
            unlink($fifo) if -e $fifo;

            # Forward the exit code from our child
            exit($exit);
        };

        for (1 .. 10) {
            last if open($fh, '>', $fifo);
            die "Could not open fifo ($fifo): $!" unless $! == EINTR;
            Time::HiRes::sleep(0.2);
        }
        die "Could not open fifo ($fifo): $!" unless $fh;

        $fh->autoflush(1);
        my $guard = Scope::Guard->new($cleanup);

        while (1) {
            my $data = <STDIN>;
            if (defined($data) && length($data)) {
                print $fh $data;
                next;
            }

            next if defined($data);

            next if kill(0, $pid);
            print STDERR "Lost child process $pid\n";
            $cleanup->();
            exit 255;
        }
    }

    close(STDIN);
    open(STDIN, '<', '/dev/null');

    while (!-e $fifo) { Time::HiRes::sleep(0.02) }
}

sub _post_process_version ($options, $state) {
    my $settings = $state->{settings};

    return unless $settings->debug->version;

    require App::Yath2;
    my $out = <<"    EOT";

Yath version: $App::Yath2::VERSION

Extended Version Info
    EOT

    my $plugin_libs = find_libraries('App::Yath2::Plugin::*');

    my @vers = (
        [perl         => $^V],
        ['App::Yath2' => App::Yath2->VERSION],
        (
            map {
                my $ok = eval { require(mod2file($_)); 1 };
                $ok
                    ? [$_ => $_->VERSION // 'N/A']
                    : [$_ => 'N/A']
            } qw/Test2::API Test2::Suite Test::Builder/
        ),
        (
            map {
                my $ok = eval { require($plugin_libs->{$_}); 1 };
                $ok ? [$_ => $_->VERSION // 'N/A'] : ()
            } sort keys %$plugin_libs
        ),
    );

    $out .= join "\n" => table(
        header => [qw/COMPONENT VERSION/],
        rows   => \@vers,
    );

    print "$out\n\n";

    exit 0;
}

1;

__END__

=pod

=encoding UTF-8

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
