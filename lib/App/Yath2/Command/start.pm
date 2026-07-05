package App::Yath2::Command::start;
use strict;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

our $VERSION = '2.000000';

use App::Yath2::Util qw/find_runner_link/;
use Getopt::Yath;

use App::Yath2::Client;
use App::Yath2::Discovery;

use Test2::Harness2::Util qw/parse_exit clean_path/;

use POSIX;

use Time::HiRes qw/sleep/;

use File::Spec();
use File::Path qw/remove_tree/;

use parent 'App::Yath2::Command';
use Test2::Harness2::Util::HashBase qw/+client/;

include_options(
    'App::Yath2::Options::Debug',
    'App::Yath2::Options::PreCommand',
    'App::Yath2::Options::Runner',
    'App::Yath2::Options::Workspace',
    'App::Yath2::Options::Persist',
    'App::Yath2::Options::Collector',
);

option_group {group => 'runner', category => "Persistent Runner Options"} => sub {
    option reload => (
        short       => 'r',
        type        => 'Bool',
        description => "Attempt to reload modified modules in-place, restarting entire stages only when necessary.",
        default     => 0,
    );

    option restrict_reload => (
        type           => 'AutoPathList',
        autofill       => 1,
        long_examples  => ['', '=path'],
        short_examples => ['', '=path'],
        description    => "Only reload modules under the specified path, if no path is specified look at anything under the .yath.rc path, or the current working directory.",

        # Keep the '1' sentinel until the trigger so we can resolve the
        # bare-flag case to the rc-file dir (or cwd) at parse time.
        normalize => sub ($val) { $val eq '1' ? $val : clean_path($val) },

        # action -> trigger: fires BEFORE add_value. Reshape @{$params{val}},
        # replacing the '1' sentinel with the resolved default path.
        trigger => sub ($opt, %params) {
            return unless $params{action} eq 'set';

            my $settings = $params{settings};
            for my $val (@{$params{val}}) {
                next unless $val eq '1';

                my $hset = $settings->harness;
                my $path = ($hset->check_option('config_file') ? $hset->config_file : undef)
                    || ($hset->check_option('cwd') ? $hset->cwd : undef);
                $path //= do { require Cwd; Cwd::getcwd() };
                $path =~ s{\.yath\.rc$}{}g;
                $val = $path;
            }
        },
    );

    option quiet => (
        short       => 'q',
        type        => 'Count',
        description => "Be very quiet.",
        initialize  => 0,
    );
};

sub group { 'persist' }

sub always_keep_dir { 1 }

sub summary  { "Start the persistent test runner" }
sub cli_args { "" }

sub description {
    return <<"    EOT";
This command is used to start a persistant instance of yath. A persistant
instance is useful because it allows you to preload modules in advance,
reducing start time for any tests you decide to run as you work.

A running instance will watch for changes to any preloaded files, and restart
itself if anything changes. Changed files are blacklisted for subsequent
reloads so that reloading is not a frequent occurence when editing the same
file over and over again.
    EOT
}

# The start-mode harness-client: it spawns the persistent runner under its own
# non-test collector (the same Test2::Harness2::Runner->start_collected wrap the
# transient path uses), so the runner's stdout/stderr/exit are recorded as
# first-class events in runner-events.jsonl.zst -- read back over runner.socket by
# `yath watch`. start_collected detaches the daemon collector parent's
# stdout/stderr to /dev/null so a daemon does not hold this command's caller pipe
# open. The client builds the runner command (the persistent-runner args are
# threaded through start_runner); a persistent runner takes no plugin spawn args.
sub client {
    my $self = shift;

    return $self->{+CLIENT} //= App::Yath2::Client->new(
        workdir          => $self->settings->workspace->workdir,
        settings         => $self->settings,
        mode             => 'start',
        spawn_args       => [],
        monitor_preloads => 1,
    );
}

sub run {
    my $self = shift;

    my $settings = $self->settings;
    my $dir      = $settings->workspace->workdir;

    # The discovery SYMLINK path (a link to this runner's runner.socket). vivify
    # gives the path to publish; it does not create the link.
    my $link = find_runner_link($settings, vivify => 1)
        or die "Could not determine a discovery path for the current settings.\n";

    # A runner already publishing this symlink blocks a fresh start. Probe it in
    # EVERY state (any_state): a LIVE runner is already running; a NOT-LIVE one
    # (booting, wedged, full accept backlog, another user's) must NOT be silently
    # replaced -- it stays discoverable so `yath kill` can reach it (ticket TODO-145). A
    # truly DEAD stale link is cleaned by find() (via the locked owned protocol) and
    # we fall through to start fresh.
    if (my $found = App::Yath2::Discovery->find($settings, any_state => 1)) {
        my $state = $found->state;

        if ($state ne 'dead') {
            $self->_maybe_remove_workdir($dir, $found);

            die "Persistent harness appears to be running, found $link\n"
                if $state eq 'live';

            my $fpid = $found->pid // 'unknown';
            my $fdir = eval { $found->workdir } // 'unknown';
            die "Persistent runner found but not responding (pid $fpid, dir $fdir); use `yath kill`\n";
        }
    }

    $self->write_settings_to($dir, 'settings.json');

    # Plugin setup() runs in the persistent RUNNER (after runner.socket binds),
    # not here -- aux work reports to the socket as events.
    $self->setup_resources();

    my $pid = $self->client->start_runner(
        persist   => $link,
        jobs_todo => 0,
    );

    # The RUNNER self-publishes the discovery symlink (link -> $dir/runner.socket)
    # from inside its own process, immediately after it binds runner.socket -- see
    # Test2::Harness2::Runner (fork A of ticket TODO-145). start no longer publishes:
    # publishing here (before the socket is bound) is exactly the race that let a
    # concurrent discovery command unlink the not-yet-live link. We only build the
    # read-side object to poll $dir/PID for the banner (pid() reads the workdir PID
    # file directly; no link needed).
    my $disco = App::Yath2::Discovery->new(link => $link, workdir => $dir);

    # The runner pid for the banner: prefer the runner's own pid (from $dir/PID,
    # which survives an exec across a reload-respawn), falling back to the collector
    # parent pid run_cmd returned if the file has not appeared yet.
    my $runner_pid = $self->wait_for_runner_pid($disco);

    # TODO-123: gate the "started!" banner on a bounded LIVENESS check. A PID file proves
    # only that the runner forked -- it is written BEFORE runner.socket is bound and
    # BEFORE the preload tree is spawned, so a broken -P module still takes the
    # fail-fast path (Runner::_handle_dead_preload_root) and exits after writing PID.
    # The old daemon branch printed success + exited 0 here regardless, so
    # `yath start -d -PBroken && yath run` proceeded on a false success and then failed
    # with an unexplained 'No persistent harness was found'. Confirm the runner is
    # actually SERVING (runner.socket resolves live -- TODO-145's probe) before the banner,
    # and report honestly + exit nonzero if it exited or never came up.
    unless (defined $runner_pid) {
        return $self->_report_start_failure($dir, $pid, "it exited before writing its PID file");
    }

    my $live = $self->wait_for_runner_live($disco);
    unless ($live eq 'live') {
        my $reason = $live eq 'gone'
            ? "it exited before it began serving on runner.socket (a broken preload?)"
            : "it never began serving on runner.socket within ${\ $self->LIVENESS_TIMEOUT}s";

        return $self->_report_start_failure($dir, $runner_pid, $reason);
    }

    unless ($settings->runner->quiet) {
        print "\nPersistent runner started!\n";

        print "Runner PID: $runner_pid\n";
        print "Runner dir: $dir\n";
        print "\nUse `yath watch` to monitor the persistent runner\n\n" if $settings->runner->daemon;
    }

    return 0 if $settings->runner->daemon;

    $SIG{TERM} = sub { kill(TERM => $pid) };
    $SIG{INT}  = sub { kill(INT  => $pid) };

    # Foreground (--no-daemon): wait for the runner to exit. Its output is no
    # longer tailed from flat logs here -- it lives in runner-events.jsonl.zst and
    # is surfaced over runner.socket by `yath watch`.
    local $?;
    while (1) {
        my $out = waitpid($pid, WNOHANG);

        if ($out == 0) {
            sleep(0.05);
            next;
        }

        return 255 if $out < 0;

        my $exit = parse_exit($?);
        return $exit->{err} || $exit->{sig} || 0;
    }
}

# Guarded cleanup of the workdir on the already-running / not-responding abort path
# (ticket TODO-145, finding 64). The unguarded remove_tree here used to delete ANY
# user-pinned workdir -- including the LIVE runner's own when YATH_WORKDIR was reused
# -- orphaning an unstoppable daemon. Remove $dir ONLY when it was freshly created
# for THIS invocation (Workspace's created_workdir flag), is NOT the found runner's
# own workdir (found via any_state, so a NOT-LIVE runner's dir is protected too), and
# holds neither a runner.socket nor a PID file (cheap paranoia against a lying flag).
sub _maybe_remove_workdir {
    my $self = shift;
    my ($dir, $found) = @_;

    my $workspace = $self->settings->workspace;
    my $created = $workspace->check_option('created_workdir') ? $workspace->created_workdir : 0;
    return unless $created;

    my $found_dir = eval { $found->workdir };
    return if defined($found_dir) && $found_dir eq $dir;

    return if -e File::Spec->catfile($dir, 'runner.socket');
    return if -e File::Spec->catfile($dir, 'PID');

    remove_tree($dir, {safe => 1, keep_root => 0});
    return;
}

# Bounded window (seconds) for both boot waits below. Env-overridable (pure
# superset: unset => the documented default) so the regression tests can shrink the
# window instead of sitting through the full boot budget. Bounded so a runner that
# forks but never comes up can never hang `yath start` (TODO-123).
sub LIVENESS_TIMEOUT { $ENV{YATH_START_LIVENESS_TIMEOUT} // 30 }

# Poll for the runner's own pid, which the runner writes to $dir/PID as it boots
# (Test2::Harness2::Runner::process) and which survives the exec across a
# reload-respawn. Discovery reads this PID file as the signal fallback; here it
# gates the TODO-123 liveness wait and feeds the start banner. Returns the pid, or undef
# if the runner exits before writing it (an early boot crash) or the window elapses
# -- the caller then reports an honest failure instead of a false success.
sub wait_for_runner_pid {
    my $self = shift;
    my ($disco) = @_;

    my $deadline = Time::HiRes::time() + $self->LIVENESS_TIMEOUT;

    while (1) {
        my $pid = $disco->pid;
        return $pid if defined($pid) && length($pid);

        # The runner (its collector-wrapped child) is already reaped: it died before
        # it could write its PID. Stop now rather than stalling the whole window --
        # the old `for (1 .. 600)` sat here in silence for ~30s on a boot crash (TODO-123).
        return undef if $self->client->runner_gone;
        return undef if Time::HiRes::time() >= $deadline;

        sleep(0.05);
    }
}

# The TODO-123 readiness gate: after the PID file appears, confirm the runner is actually
# SERVING before the success banner. Poll TODO-145's probe() until runner.socket resolves
# LIVE (accepts a connection -- the runner self-publishes the discovery link only
# AFTER it binds the socket, so a live probe proves the socket is up), or bail the
# moment the runner process is gone (its collector child reaped -- the deterministic
# broken-preload / boot-crash signal), or time out. Death is checked FIRST each poll:
# a runner that exited can never serve, so we report it immediately instead of waiting
# out the window. Returns 'live' on success, or the failure subcode 'gone'/'timeout'.
sub wait_for_runner_live {
    my $self = shift;
    my ($disco) = @_;

    my $deadline = Time::HiRes::time() + $self->LIVENESS_TIMEOUT;

    while (1) {
        return 'gone' if $self->client->runner_gone;
        return 'live' if $disco->resolves;
        return 'timeout' if Time::HiRes::time() >= $deadline;

        sleep(0.05);
    }
}

# Honest failure on the start path (TODO-123). The runner forked but never came up to
# serve, so instead of the old silent exit-0 (which let a later `yath run` fail with
# an unexplained 'No persistent harness was found') point the user at the runner's
# own recorded output (runner-events.jsonl.zst, surfaced by `yath watch`) and return
# a nonzero exit. Printed even under --quiet: a failed start is not chatter.
sub _report_start_failure {
    my $self = shift;
    my ($dir, $pid, $reason) = @_;

    my $where = (defined($pid) && length($pid)) ? " (pid $pid)" : "";
    print STDERR "\nPersistent runner failed to start$where: $reason.\n";
    print STDERR "Runner dir: $dir\n";
    print STDERR "Inspect the runner's output with: yath watch\n\n";

    return 1;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::start - Start the persistent test runner

=head1 DESCRIPTION

This command is used to start a persistant instance of yath. A persistant
instance is useful because it allows you to preload modules in advance,
reducing start time for any tests you decide to run as you work.

A running instance will watch for changes to any preloaded files, and restart
itself if anything changes. Changed files are blacklisted for subsequent
reloads so that reloading is not a frequent occurence when editing the same
file over and over again.


=head1 USAGE

    $ yath [YATH OPTIONS] start [OPTIONS]

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

=head3 Collector Options

=over 4

=item --max-open-jobs 18

=item --no-max-open-jobs

Maximum number of jobs a collector can process at a time, if more jobs are pending their output will be delayed until the earlier jobs have been processed. (Default: double the -j value)


=item --max-poll-events 1000

=item --no-max-poll-events

Maximum number of events to poll from a job before jumping to the next job. (Default: 1000)


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

=head3 Persistent Runner Options

=over 4

=item -q

=item -qq

=item -qqq..

=item -q=COUNT

=item --quiet

=item --quiet=COUNT

=item --no-quiet

Be very quiet.

Note: Can be specified multiple times, counter bumps each time it is used.


=item -r

=item --reload

=item --no-reload

Attempt to reload modified modules in-place, restarting entire stages only when necessary.


=item --restrict-reload

=item --restrict-reload=path

=item --no-restrict-reload

Only reload modules under the specified path, if no path is specified look at anything under the .yath.rc path, or the current working directory.

Note: Can be specified multiple times


=back

=head3 Runner Options

=over 4

=item --abort-on-bail

=item --no-abort-on-bail

Abort all testing if a bail-out is encountered (default: on)


=item -b

=item --blib

=item --no-blib

(Default: include if it exists) Include 'blib/lib' and 'blib/arch' in your module path


=item --cover

=item --cover=-silent,1,+ignore,^t/,+ignore,^t2/,+ignore,^xt,+ignore,^test.pl

=item --no-cover

Use Devel::Cover to calculate test coverage. This disables forking. If no args are specified the following are used: -silent,1,+ignore,^t/,+ignore,^t2/,+ignore,^xt,+ignore,^test.pl

Can also be set with the following environment variables: C<T2_DEVEL_COVER>

The following environment variables will be set after arguments are processed: C<T2_DEVEL_COVER>


=item --daemon

=item --no-daemon

Start the runner as a daemon (Default: True)


=item --dump-depmap

=item --no-dump-depmap

When using staged preload, dump the depmap for each stage as json files


=item --et SECONDS

=item --event-timeout SECONDS

=item --no-event-timeout

Kill test if no output is received within timeout period. (Default: 60 seconds). Add the "# HARNESS-NO-TIMEOUT" comment to the top of a test file to disable timeouts on a per-test basis. This prevents a hung test from running forever.


=item --fail-on-resource-skip

=item --no-fail-on-resource-skip

Treat resource-skipped tests as failures instead of skips. When enabled, tests that would be skipped due to unavailable resources will be marked as failing.


=item -I ARG

=item -I=ARG

=item -I '["json","list"]'

=item -I='["json","list"]'

=item --include ARG

=item --include=ARG

=item --include '["json","list"]'

=item --include='["json","list"]'

=item --no-include

Add a directory to your include paths

Note: Can be specified multiple times


=item -j4

=item -j8:2

=item --jobs 4

=item --jobs 8:2

=item --job-count 4

=item --job-count 8:2

=item --no-job-count

Set the number of concurrent jobs to run. Add a :# if you also wish to designate multiple slots per test. 8:2 means 8 slots, but each test gets 2 slots, so 4 tests run concurrently. Tests can find their concurrency assignemnt in the "T2_HARNESS_MY_JOB_CONCURRENCY" environment variable.

Can also be set with the following environment variables: C<YATH_JOB_COUNT>, C<T2_HARNESS_JOB_COUNT>, C<HARNESS_JOB_COUNT>

The following environment variables will be cleared after arguments are processed: C<YATH_JOB_COUNT>, C<T2_HARNESS_JOB_COUNT>, C<HARNESS_JOB_COUNT>


=item -l

=item --lib

=item --no-lib

(Default: include if it exists) Include 'lib' in your module path


=item --nytprof

=item --no-nytprof

Use Devel::NYTProf on tests. This will set addpid=1 for you. This works with or without fork.


=item --pet SECONDS

=item --post-exit-timeout SECONDS

=item --no-post-exit-timeout

Stop waiting post-exit after the timeout period. (Default: 15 seconds) Some tests fork and allow the parent to exit before writing all their output. If Test2::Harness2 detects an incomplete plan after the test exits it will monitor for more events until the timeout period. Add the "# HARNESS-NO-TIMEOUT" comment to the top of a test file to disable timeouts on a per-test basis.


=item -WARG

=item -W ARG

=item -W=ARG

=item --Pt ARG

=item --Pt=ARG

=item --preload-threshold ARG

=item --preload-threshold=ARG

=item --no-preload-threshold

Only do preload if at least N tests are going to be run. In some cases a full preload takes longer than simply running the tests, this lets you specify a minimum number of test jobs that will be run for preload to happen. This has no effect for a persistent runner. The default is 0, and it means always preload.


=item -P ARG

=item -P=ARG

=item -P '["json","list"]'

=item -P='["json","list"]'

=item --preload ARG

=item --preload=ARG

=item --preloads ARG

=item --preloads=ARG

=item --preload '["json","list"]'

=item --preload='["json","list"]'

=item --preloads '["json","list"]'

=item --preloads='["json","list"]'

=item --no-preloads

Preload a module before running tests

Note: Can be specified multiple times


=item -R Port

=item --resource Port

=item --resource +Test2::Harness2::Runner::Resource::Port

=item --no-resource

Use a resource module to assign resource assignments to individual tests

Note: Can be specified multiple times


=item --rt SECONDS

=item --resource-timeout SECONDS

=item --no-resource-timeout

Abort the test run if no tests have been able to start for SECONDS seconds while there are pending tests and none running. This is useful when a resource class is broken and always claims a resource will become available, preventing yath from ever finishing. (Default: 0, meaning no timeout)


=item --runner-id ARG

=item --runner-id=ARG

=item --no-runner-id

Runner ID (usually a generated uuid)


=item -x2

=item --slots-per-job 2

=item --no-slots-per-job

This sets the number of slots each job will use (default 1). This is normally set by the ':#' in '-j#:#'.

Can also be set with the following environment variables: C<T2_HARNESS_JOB_CONCURRENCY>

The following environment variables will be cleared after arguments are processed: C<T2_HARNESS_JOB_CONCURRENCY>


=item -S ARG

=item -S=ARG

=item -S '["json","list"]'

=item -S='["json","list"]'

=item --switch ARG

=item --switch=ARG

=item --switch '["json","list"]'

=item --switch='["json","list"]'

=item --no-switch

Pass the specified switch to perl for each test. This is not compatible with preload.

Note: Can be specified multiple times


=item --tlib

=item --no-tlib

(Default: off) Include 't/lib' in your module path


=item --unsafe-inc

=item --no-unsafe-inc

perl is removing '.' from @INC as a security concern. This option keeps things from breaking for now.

Can also be set with the following environment variables: C<PERL_USE_UNSAFE_INC>


=item --fork

=item --use-fork

=item --no-use-fork

(default: on, except on windows) Normally tests are run by forking, which allows for features like preloading. This will turn off the behavior globally (which is not compatible with preloading). This is slower, it is better to tag misbehaving tests with the '# HARNESS-NO-PRELOAD' comment in their header to disable forking only for those tests.

Can also be set with the following environment variables: C<!T2_NO_FORK>, C<T2_HARNESS_FORK>, C<!T2_HARNESS_NO_FORK>, C<YATH_FORK>, C<!YATH_NO_FORK>


=item --timeout

=item --use-timeout

=item --no-use-timeout

(default: on) Enable/disable timeouts


=back

=head3 Workspace Options

=over 4

=item -C

=item --clear

=item --no-clear

Clear the work directory if it is not already empty


=item -tARG

=item -t ARG

=item -t=ARG

=item --tmpdir ARG

=item --tmpdir=ARG

=item --tmp-dir ARG

=item --tmp-dir=ARG

=item --tmp-dir ARG

=item --tmp-dir=ARG

=item --no-tmp-dir

Use a specific temp directory (Default: use system temp dir)

Can also be set with the following environment variables: C<T2_HARNESS_TEMP_DIR>, C<YATH_TEMP_DIR>, C<TMPDIR>, C<TEMPDIR>, C<TMP_DIR>, C<TEMP_DIR>


=item -wARG

=item -w ARG

=item -w=ARG

=item --workdir ARG

=item --workdir=ARG

=item --no-workdir

Set the work directory (Default: new temp directory)

Can also be set with the following environment variables: C<T2_WORKDIR>, C<YATH_WORKDIR>

The following environment variables will be cleared after arguments are processed: C<T2_WORKDIR>, C<YATH_WORKDIR>


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


=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness2/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright 2026 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut

