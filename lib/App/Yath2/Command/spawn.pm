package App::Yath2::Command::spawn;
use strict;
use warnings;

our $VERSION = '2.000000';

use Getopt::Yath;

use Carp qw/croak/;
use Config qw/%Config/;
use Cwd qw/getcwd/;
use File::Spec();
use Time::HiRes qw/sleep time/;

use Test2::Collector::Util::Socket qw/connect_unix/;

use Test2::Harness2::Util qw/clean_path parse_exit/;
use Test2::Harness2::Util::FdPass qw/require_fdpass command_listen send_fds/;
use Test2::Harness2::Util::FdPass::Control();
use Test2::Harness2::Util::UUID qw/gen_uuid/;
use Test2::Harness2::Role::Service::Connection();

use parent 'App::Yath2::Command::run';
use Test2::Harness2::Util::HashBase;

sub group { 'persist' }

sub summary  { "Launch a perl script from the preloaded environment" }
sub cli_args { "[--] path/to/script.pl [options and args]" }

sub description {
    return <<"    EOT";
This will launch the specified script from the preloaded yath process.

NOTE: environment variables are not automatically passed to the spawned
process. You must use -e or -E (see help) to specify what environment variables
you care about.
    EOT
}

option_group {group => 'spawn', category => 'spawn options'} => sub {
    option stage => (
        short          => 's',
        type           => 'Scalar',
        description    => 'Specify the stage to be used for launching the script',
        long_examples  => [' foo'],
        short_examples => [' foo'],
        default        => 'default',
    );

    option copy_env => (
        short          => 'e',
        type           => 'List',
        description    => "Specify environment variables to pass along with their current values, can also use a regex",
        long_examples  => [' HOME', ' SHELL', ' /PERL_.*/i'],
        short_examples => [' HOME', ' SHELL', ' /PERL_.*/i'],
    );

    option env_var => (
        field          => 'env_vars',
        short          => 'E',
        type           => 'Map',
        long_examples  => [' VAR=VAL'],
        short_examples => ['VAR=VAL', ' VAR=VAL'],
        description    => 'Set environment variables for the spawn',
    );
};

sub run_script { shift @ARGV // die "No script specified" }

sub stage { $_[0]->settings->spawn->stage }

sub env_vars {
    my $self = shift;

    my $settings = $self->settings;

    my $env = {};

    for my $var (@{$settings->spawn->copy_env}) {
        if ($var =~ m{^/(.*)/(\w*)$}s) {
            my ($re, $opts) = ($1, $2);
            my $pattern = length($opts) ? "(?$opts)$re" : $re;
            $env->{$_} = $ENV{$_} for grep { m/$pattern/ } keys %ENV;
        }
        else {
            $env->{$var} = $ENV{$var};
        }
    }

    my $set = $settings->spawn->env_vars;
    $env->{$_} = $set->{$_} for keys %$set;

    return $env;
}

sub set_pname {
    my $self = shift;
    my ($run) = @_;

    $0 = "yath-" . $self->name . " $run " . join(' ', @ARGV);
}

sub pre_process_argv {
    shift @ARGV if @ARGV && $ARGV[0] eq '--';
}

# Signals the command traps and forwards over the control channel. A spawned child
# is setsid'd (no controlling terminal), so terminal-generated signals must be
# relayed by the command rather than reaching the child natively (ARCHITECTURE.md
# §4.8 limitation).
sub sig_handlers { qw/INT TERM HUP QUIT USR1 USR2 WINCH/ }

# Locate a live preload-<stage>.socket to spawn from. A user-chosen stage (-s) must
# match exactly; otherwise scan the workdir for any preload-<stage>.socket that
# accepts a connection, preferring a 'default'/'base' stage. Returns (stage, path).
sub find_stage_socket {
    my $self = shift;
    my ($workdir) = @_;

    my $chosen      = $self->stage;
    my $user_chose  = defined($chosen) && $chosen ne 'default';

    if ($user_chose) {
        my $path = File::Spec->catfile($workdir, "preload-$chosen.socket");
        die "No live preload stage '$chosen' is available for spawn (its socket is missing or not accepting).\n"
            unless $self->_socket_live($path);
        return ($chosen, $path);
    }

    my @sockets;
    if (opendir(my $dh, $workdir)) {
        for my $entry (sort readdir($dh)) {
            next unless $entry =~ /^preload-(.+)\.socket$/;
            push @sockets => [$1, File::Spec->catfile($workdir, $entry)];
        }
        closedir($dh);
    }

    # Prefer a default/base stage, then any other live stage.
    my @ordered = (
        (grep { $_->[0] eq 'default' || $_->[0] eq 'base' } @sockets),
        (grep { $_->[0] ne 'default' && $_->[0] ne 'base' } @sockets),
    );

    for my $pair (@ordered) {
        return @$pair if $self->_socket_live($pair->[1]);
    }

    die "No live preload stage is available for spawn. 'yath spawn' requires a persistent runner started with a preload (yath start -P...).\n";
}

sub _socket_live {
    my $self = shift;
    my ($path) = @_;

    return 0 unless -S $path;
    my $sock = eval { connect_unix($path) } or return 0;
    close($sock);
    return 1;
}

# Open a Role::Service connection to the chosen preload stage and send the spawn
# request, pumping until the stage's async {ok=>1} ack (or a structured rejection)
# arrives. Returns the ack hashref. The connection is transient and separate from
# the IO path (the supervisor dials BACK to our listen socket) -- close it after.
sub request_spawn {
    my $self = shift;
    my ($socket_path, $request) = @_;

    my $fh = connect_unix($socket_path)
        or die "Could not connect to preload stage socket '$socket_path': $!\n";
    $fh->blocking(0);

    my $conn = Test2::Harness2::Role::Service::Connection->new(
        fh          => $fh,
        outbound    => 1,
        my_identity => 'yath-spawn',
    );

    my $request_id = $conn->send_request('spawn', spawn => $request);
    die "Could not send spawn request to the preload stage (connection lost).\n"
        unless $request_id;

    my $deadline = time + 30;
    while (1) {
        die "Timed out waiting for the preload stage to accept the spawn.\n"
            if time > $deadline;

        my @events = $conn->drain;
        for my $event (@events) {
            next unless $event->{kind} eq 'response';
            next unless ($event->{request_id} // '') eq $request_id;
            $conn->close;
            return $event->{payload} // {};
        }

        die "The preload stage closed the connection before accepting the spawn.\n"
            if $conn->closed;

        sleep 0.02 unless @events;
    }
}

sub run {
    my $self = shift;

    $self->pre_process_argv;

    # Fail early (at the command, before any work) with an actionable message if the
    # optional fd-passing module is absent -- never as a raw load failure deep in the
    # stage. 'yath spawn' is meaningless without it (the whole point is handing the
    # child the real terminal descriptors).
    require_fdpass('yath spawn');

    my $script = $self->run_script;
    $self->set_pname($script);

    my $cwd      = clean_path(getcwd());
    my $abs_path = clean_path(File::Spec->file_name_is_absolute($script) ? $script : File::Spec->catfile($cwd, $script));

    my $workdir = $self->workdir;

    my ($stage, $socket_path) = $self->find_stage_socket($workdir);

    # The command listens; the spawned side dials back (ARCHITECTURE.md §4.8). Open
    # the listen socket up front so its path can ride the spawn request.
    my ($listen, $listen_path) = command_listen();

    my $correlation_id = gen_uuid();

    my $ack = $self->request_spawn(
        $socket_path,
        {
            file               => $script,
            abs_path           => $abs_path,
            cwd                => $cwd,
            args               => [@ARGV],
            env_vars           => $self->env_vars,
            correlation_id     => $correlation_id,
            listen_socket_path => $listen_path,
        },
    );

    unless ($ack->{ok}) {
        my $why = $ack->{error} // 'the preload stage rejected the spawn';
        die "Could not spawn: $why.\n";
    }

    my $exit = $self->bridge_io($listen);

    if ($exit->{sig}) {
        # Resolve the numeric signal to a name for the message only: a NUMERIC %SIG
        # key ($SIG{15}) is rejected by Perl (a spurious 'No such signal: SIG15'
        # warning, and no handler installed), and the only handlers this command ever
        # sets -- _install_sig_forwarding's -- were already reset to DEFAULT by name in
        # _clear_sig_forwarding (bridge_io tail), so no %SIG write is needed here.
        my $name = (split /\s+/, $Config{sig_name})[$exit->{sig}] // "signal $exit->{sig}";
        print STDERR "Terminated with signal: $name.\n";
        kill($exit->{sig}, $$);

        # If the fatal signal's disposition was inherited-ignored (e.g. PIPE under
        # some process supervisors -- untrapped, so _clear_sig_forwarding never
        # touched it), the re-raise above is discarded; exit 128+sig rather than
        # falling through to exit($exit->{err}) == exit(0).
        exit(128 + $exit->{sig});
    }

    print STDERR "Exited with code: $exit->{err}.\n" if $exit->{err};

    exit($exit->{err});
}

# Phase two of the one connection: accept the supervisor's dial-back, pass our REAL
# STDIN/STDOUT/STDERR over SCM_RIGHTS (the child reads/writes the real terminal,
# the command leaves the byte path entirely), then flip the same socket to the
# dedicated control protocol. Trap + forward signals to the supervisor (a setsid'd
# child cannot receive terminal-generated signals natively), and block on the
# control channel until the supervisor reports the child's raw wait status. Returns
# the parsed exit (sig/err). Closing the control connection (or the command dying)
# is the supervisor's "kill the child" signal -- the spawned process is bound to its
# command (ARCHITECTURE.md §4.8).
sub bridge_io {
    my $self = shift;
    my ($listen) = @_;

    my $conn = $self->_accept_supervisor($listen);
    close($listen);

    send_fds($conn, [fileno(\*STDIN), fileno(\*STDOUT), fileno(\*STDERR)]);

    my $ctl = Test2::Harness2::Util::FdPass::Control->new(fh => $conn);

    # The supervisor announces its pid as the first control frame.
    my $hello = $ctl->read_message;
    die "The spawn supervisor closed the control channel before reporting itself.\n"
        unless $hello && $hello->{hello};

    $self->_install_sig_forwarding($ctl);

    # Track whether an exit_status frame actually arrived. A supervisor that was
    # OOM-killed/crashed between hello and exit_status (or whose final _send failed)
    # closes the control channel WITHOUT one -- that must NOT be reported as a clean
    # exit 0 (the setsid'd script may still be running detached). The exit_status test
    # runs BEFORE the closed-break, and the closed-break requires !$msg, so a buffered
    # frame delivered together with EOF (fast exit) is drained and honored first
    # (Control::read_message takes before it fills).
    my ($status, $got_exit) = (0, 0);
    while (1) {
        my $msg = $ctl->read_message;
        if ($msg && $msg->{exit_status}) {
            $status    = $msg->{exit_status}{status} // 0;
            $got_exit  = 1;
            last;
        }
        last if $ctl->closed && !$msg;
    }

    $self->_clear_sig_forwarding();
    $ctl->close;

    unless ($got_exit) {
        print STDERR "yath spawn: the spawn supervisor vanished before reporting an exit status; the spawned script may still be running.\n";
        return parse_exit(255 << 8);
    }

    return parse_exit($status);
}

sub _accept_supervisor {
    my $self = shift;
    my ($listen) = @_;

    $listen->blocking(0);

    my $deadline = time + 30;
    while (1) {
        my $conn = $listen->accept;
        if ($conn) {
            $conn->blocking(1);
            return $conn;
        }

        die "Timed out waiting for the spawn supervisor to connect back.\n"
            if time > $deadline;

        sleep 0.02;
    }
}

sub _install_sig_forwarding {
    my $self = shift;
    my ($ctl) = @_;

    for my $sig ($self->sig_handlers) {
        $SIG{$sig} = sub { $ctl->send_signal($sig) };
    }

    return;
}

sub _clear_sig_forwarding {
    my $self = shift;

    $SIG{$_} = 'DEFAULT' for $self->sig_handlers;

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::spawn - Launch a perl script from the preloaded environment

=head1 DESCRIPTION

This will launch the specified script from the preloaded yath process.

NOTE: environment variables are not automatically passed to the spawned
process. You must use -e or -E (see help) to specify what environment variables
you care about.


=head1 USAGE

    $ yath [YATH OPTIONS] spawn [OPTIONS]

=head2 OPTIONS

=head3 Plugins

=over 4

=item --no-scan-plugins

=item --no-no-scan-plugins

Normally yath scans for and loads all App::Yath2::Plugin::* modules in order to bring in command-line options they may provide. This flag will disable that. This is useful if you have a naughty plugin that is loading other modules when it should not.


=item -pPLUGIN

=item --plugin PLUGIN

=item --plugins PLUGIN

=item --plugin PLUGIN=arg1,arg2,...

=item --plugins PLUGIN=arg1,arg2,...

=item --plugin +App::Yath2::Plugin::PLUGIN

=item --plugins +App::Yath2::Plugin::PLUGIN

=item --no-plugins

Load a yath plugin.

Note: Can be specified multiple times


=back

=head3 Environment

=over 4

=item --persist-dir ARG

=item --persist-dir=ARG

=item --no-persist-dir

Where to find persistence files.


=item --pfile ARG

=item --pfile=ARG

=item --persist-file ARG

=item --persist-file=ARG

=item --no-persist-file

Where to find the persistent runner discovery symlink (a link to the runner's socket). The default is /{system-tempdir}/.project-yath-runner.sock. If no project is specified it falls back to the current directory; if the current directory is not writable it defaults to the system temp dir, which limits you to one persistent runner per project on your system.


=item --project ARG

=item --project=ARG

=item --project-name ARG

=item --project-name=ARG

=item --no-project

This lets you provide a label for your current project/codebase. This is best used in a .yath.rc file. This is necessary for a persistent runner.


=back

=head3 Developer

=over 4

=item -D

=item -Dlib

=item -D=lib

=item --dev-lib

=item --dev-lib=lib

=item --no-dev-lib

Add paths to @INC before loading ANYTHING. This is what you use if you are developing yath or yath plugins to make sure the yath script finds the local code instead of the installed versions of the same code. You can provide an argument (-Dfoo) to provide a custom path, or you can just use -D without and arg to add lib, blib/lib and blib/arch.

Note: Can be specified multiple times


=back

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

=head3 Cover Options

=over 4

=item --cover-agg ByRun

=item --cover-agg ByTest

=item --cover-aggregator ByRun

=item --cover-aggregator ByTest

=item --cover-agg +Custom::Aggregator

=item --cover-aggregator +Custom::Aggregator

=item --no-cover-aggregator

Choose a custom aggregator subclass


=item --cover-class ARG

=item --cover-class=ARG

=item --no-cover-class

Choose a Test2::Plugin::Cover subclass


=item --cover-dir ARG

=item --cover-dir=ARG

=item --cover-dirs ARG

=item --cover-dirs=ARG

=item --cover-dir '["json","list"]'

=item --cover-dir='["json","list"]'

=item --cover-dirs '["json","list"]'

=item --cover-dirs='["json","list"]'

=item --no-cover-dirs

NO DESCRIPTION - FIX ME

Note: Can be specified multiple times


=item --cover-exclude-private

=item --no-cover-exclude-private




=item --cover-files

=item --no-cover-files

Use Test2::Plugin::Cover to collect coverage data for what files are touched by what tests. Unlike Devel::Cover this has very little performance impact (About 4% difference)


=item --cover-from path/to/log.jsonl

=item --cover-from path/to/coverage.jsonl

=item --cover-from http://example.com/coverage

=item --no-cover-from

This can be a test log, a coverage dump (old style json or new jsonl format), or a url to any of the previous. Tests will not be run if the file/url is invalid.


=item --cover-from-type log

=item --cover-from-type json

=item --cover-from-type jsonl

=item --no-cover-from-type

File type for coverage source. Usually it can be detected, but when it cannot be you should specify. "json" is old style single-blob coverage data, "jsonl" is the new by-test style, "log" is a logfile from a previous run.


=item --cover-manager My::Coverage::Manager

=item --no-cover-manager

Coverage 'from' manager to use when coverage data does not provide one


=item --cover-maybe-from path/to/log.jsonl

=item --cover-maybe-from path/to/coverage.jsonl

=item --cover-maybe-from http://example.com/coverage

=item --no-cover-maybe-from

This can be a test log, a coverage dump (old style json or new jsonl format), or a url to any of the previous. Tests will coninue if even if the coverage file/url is invalid.


=item --cover-maybe-from-type log

=item --cover-maybe-from-type json

=item --cover-maybe-from-type jsonl

=item --no-cover-maybe-from-type

Same as "from_type" but for "maybe_from". Defaults to "from_type" if that is specified, otherwise auto-detect


=item --cover-metrics

=item --no-cover-metrics




=item --cover-type ARG

=item --cover-type=ARG

=item --cover-types ARG

=item --cover-types=ARG

=item --cover-type '["json","list"]'

=item --cover-type='["json","list"]'

=item --cover-types '["json","list"]'

=item --cover-types='["json","list"]'

=item --no-cover-types

NO DESCRIPTION - FIX ME

Note: Can be specified multiple times


=item --cover-write

=item --cover-write=coverage.json

=item --cover-write=coverage.jsonl

=item --no-cover-write

Create a json or jsonl file of all coverage data seen during the run (This implies --cover-files).


=back

=head3 Git Options

=over 4

=item --git-change-base HEAD^

=item --git-change-base master

=item --git-change-base df22abe4

=item --no-git-change-base

Find files changed by all commits in the current branch from most recent stopping when a commit is found that is also present in the history of the branch/commit specified as the change base.


=back

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

=head3 spawn options

=over 4

=item -e HOME

=item -e SHELL

=item -e /PERL_.*/i

=item --copy-env HOME

=item --copy-env SHELL

=item --copy-env /PERL_.*/i

=item --no-copy-env

Specify environment variables to pass along with their current values, can also use a regex

Note: Can be specified multiple times


=item -EVAR=VAL

=item -E VAR=VAL

=item --env-var VAR=VAL

=item --no-env-var

Set environment variables for the spawn

Note: Can be specified multiple times


=item -s foo

=item --stage foo

=item --no-stage

Specify the stage to be used for launching the script


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

Copyright 2026 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut

