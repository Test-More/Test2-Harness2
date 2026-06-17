package App::Yath2::Command::spawn;
use strict;
use warnings;

our $VERSION = '2.000000';

use Getopt::Yath;

use Time::HiRes qw/sleep time/;
use File::Temp qw/tempfile/;

use Test2::Harness2::Util qw/parse_exit/;

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

sub read_line {
    my ($fh, $timeout) = @_;

    $timeout //= 300;

    my $start = time;
    while (1) {
        if ($timeout < (time - $start)) {
            my @caller = caller;
            die "Timed out at $caller[1] line $caller[2].\n";
        }
        seek($fh, 0, 1) if eof($fh);
        my $out = <$fh>;
        unless (defined $out) {
            sleep 0.02;
            next;
        }
        chomp($out);
        return $out;
    }
}

# Chunk 6.1-2: submit the spawn over runner.socket (App::Yath2::Client) like the
# rest of the persistent path, instead of writing the in-process dispatch.jsonl
# State directly. The State adds id/spawn/use_preload/stage defaults in its
# _queue_spawn handler runner-side, so the raw args are enough here.
#
# Review P2: the submission is acknowledged (two-way). queue_spawn returns the
# runner's ack hash (or undef if the runner could not be reached at all). The
# caller inspects it and fails fast if the spawn was not accepted/queued, instead
# of blindly opening the worker tempfile and waiting on it (its read timeout is
# long, so a dropped spawn would otherwise hang the command for minutes).
sub queue_spawn {
    my $self = shift;
    my ($args) = @_;

    return $self->submitter->queue_spawn($args);
}

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

sub sig_handlers { qw/INT TERM HUP QUIT USR1 USR2 STOP WINCH/ }

sub set_sig_handlers {
    my $self = shift;
    my ($wpid) = @_;

    local $@;
    eval {
        my $s = $_;
        $SIG{$s} = sub { kill($s, $wpid) }
    } for $self->sig_handlers;
}

sub clear_sig_handlers {
    my $self = shift;

    local $@;
    eval { my $s = $_; $SIG{$s} = 'DEFAULT' } for $self->sig_handlers;
}

sub pre_exit_hook { }

sub run {
    my $self = shift;

    $self->pre_process_argv;

    my $run = $self->run_script;
    $self->set_pname($run);

    my ($fh, $name) = tempfile(UNLINK => 1);
    close($fh);

    my $ack = $self->queue_spawn({
        stage    => $self->stage // 'default',
        file     => $run,
        owner    => $$,
        ipcfile  => $name,
        args     => [@ARGV],
        env_vars => $self->env_vars,
    });

    # Review P2: fail fast on a missing/negative submission ack instead of waiting
    # on the worker tempfile (whose read timeout is long). undef means the runner
    # could not be reached at all; ok=>0 means it refused/could not route the spawn
    # (e.g. no live preload stage to run it).
    die "Could not submit spawn: no persistent runner is reachable.\n"
        unless defined $ack;

    unless ($ack->{ok}) {
        my $why = $ack->{error} // 'the runner rejected the spawn';
        die "Could not submit spawn: $why.\n";
    }

    open($fh, '<', $name) or die "Could not open ipcfile: $!";
    my $mpid = read_line($fh);
    my $wpid = read_line($fh);
    my $win  = read_line($fh);

    $self->set_sig_handlers($wpid);

    open(my $wfh, '>>', "/proc/$mpid/fd/$win") or die "Could not open /proc/$mpid/fd/$win: $!";
    $wfh->autoflush(1);
    STDIN->blocking(0);
    while (0 < kill(0, $mpid)) {
        my $line = <STDIN>;
        if (defined $line) {
            print $wfh $line;
        }
        else {
            sleep 0.02;
        }
    }

    $self->clear_sig_handlers();

    my $exit = read_line($fh) // die "Could not get exit code";
    $exit = parse_exit($exit);
    if ($exit->{sig}) {
        print STDERR "Terminated with signal: $exit->{sig}.\n";
        kill($exit->{sig}, $$);
    }

    print STDERR "Exited with code: $exit->{err}.\n" if $exit->{err};

    $self->pre_exit_hook($exit);

    exit($exit->{err});
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

Where to find the persistence file. The default is /{system-tempdir}/project-yath-persist.json. If no project is specified then it will fall back to the current directory. If the current directory is not writable it will default to /tmp/yath-persist.json which limits you to one persistent runner on your system.


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

