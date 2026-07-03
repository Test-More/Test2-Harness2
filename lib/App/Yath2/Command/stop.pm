package App::Yath2::Command::stop;
use strict;
use warnings;

our $VERSION = '2.000000';

use Time::HiRes qw/sleep time/;

use File::Spec();

use Test2::Harness2::Util::File::JSON();
use Test2::Harness2::Util::Queue();

use Test2::Harness2::Renderer::Base();
use Test2::Harness2::Runner::Monitor();
use Test2::Harness2::Util::UUID qw/gen_uuid/;

use App::Yath2::Client;
use App::Yath2::Discovery();
use App::Yath2::RenderLoop;
use App::Yath2::RenderLoop::LiveProducer;

use Test2::Harness2::Util qw/open_file/;
use File::Path qw/remove_tree/;

use parent 'App::Yath2::Command::run';
use Test2::Harness2::Util::HashBase;

sub group { 'persist' }

sub summary { "Stop the persistent test runner" }
sub cli_args { "" }

sub description {
    return <<"    EOT";
This command will stop a persistent instance, and output any log contents.
    EOT
}

# any_state: we want the Discovery object in EVERY state (live/not_live/dead) so we
# can route off #145's probe taxonomy and reach the workdir PID file with the socket
# dead. Pfile::find passes unknown params straight through to Discovery->find.
sub pfile_params { (any_state => 1) }

# Stop the persistent runner, driven by #145's discovery taxonomy (ticket #121):
#
#   LIVE      -> graceful 'stop'+end_queue over the socket, drain teardown, then a
#                BOUNDED wait for the pid to exit (shared 30s deadline). Gone =>
#                clean + exit 0. Still alive at the deadline => NO signal (stop never
#                escalates), diag + exit 1, link/workdir left for `yath kill`.
#   NOT-LIVE  -> boot/wedged/backlog with a live pid: NO socket, NO signal, diag +
#                exit 1 (`yath kill`'s job). foreign/inaccessible/unknown or no pid:
#                ambiguous => diag + exit 2, touch nothing.
#   DEAD      -> nothing to signal (ESRCH-confirmed / workdir gone) => clean + exit 0.
#   (none)    -> pfile() dies "No persistent harness was found ...".
sub run {
    my $self = shift;

    my $disco = $self->pfile->discovery;    # dies (NONE) when there is no link at all
    my $state = $disco->state;

    $self->pfile_data;    # print the Found/PID/Dir banner once (pid may be unknown)

    # Defensive: an ESRCH-confirmed pid on a not-live row routes to DEAD (the taxonomy
    # already sends ESRCH rows to DEAD, but pid_live==0 is the belt-and-suspenders).
    $state = 'dead'
        if $state eq 'not_live' && defined($disco->pid_live) && $disco->pid_live == 0;

    return $self->_stop_live($disco)     if $state eq 'live';
    return $self->_stop_dead($disco)     if $state eq 'dead';
    return $self->_stop_not_live($disco);    # not_live
}

sub _stop_live {
    my ($self, $disco) = @_;

    # A live socket with a missing/garbled workdir PID file (external deletion or
    # corruption only -- the PID is written before the socket binds) leaves
    # $disco->pid undef; attaching/kill(0)-ing on an undef pid used to misbehave.
    # Fail fast with an actionable message instead (#146).
    my $pid = $disco->pid
        // die "Runner found at " . $disco->workdir . " but its PID file is missing/unreadable; restart the runner.\n";

    # One shared absolute deadline for the drain AND the exit-wait, so a healthy stop
    # adds NO latency (the drain already exits shortly after pid death) while a wedged
    # runner is bounded to the single 30s window rather than stacking two. Declared
    # here and assigned below (after prime + attach, matching the pre-loop timing);
    # the render loop's done_check closes over it so drain and exit-wait share it.
    my $deadline;

    # Plugin teardown() runs in the RUNNER as it shuts down. Build + PRIME the
    # shutdown render loop BEFORE we trigger shutdown (LIVE-only: connect_subscriber
    # must never run when the socket is not live -- deps (b)), so its tail readers
    # sit at the current end and it renders ONLY the teardown output the runner is
    # about to write. Returns undef when runner output is hidden (loop skipped).
    my $loop;
    my $ok = eval { $loop = $self->build_shutdown_loop($pid, \$deadline); 1 };
    my $err = $@;
    warn "Could not prime runner shutdown renderer: $err" unless $ok;

    # The runner already exists; attach the client to it (kill(0) liveness, no reap).
    $self->client->attach_runner($pid);

    $deadline = time + $self->STOP_DEADLINE;

    # Graceful 'stop' (the runner translates it into its own TERM teardown) + the
    # end_queue fallback. Both are alarm-backstopped: the eval alone is INSUFFICIENT
    # because a blocking connect never returns, so nothing dies into it (deps (a)).
    ($ok, $err) = $self->_with_alarm(35, sub { $self->client->submitter->stop });
    warn "Could not send graceful shutdown to runner over socket: $err" unless $ok;

    ($ok, $err) = $self->_with_alarm(35, sub { $self->client->submitter->end_queue });
    warn "Could not end runner queue: $err" unless $ok;

    # Drain the runner's teardown output through the render loop (its done_check is
    # the stop-specific terminal predicate) then finish the renderers. Replaces the
    # old hand-stepped drain; on the hidden-output path $loop is undef so the
    # renderers are never stepped/finished (today's behavior preserved).
    my $rendered = eval { if ($loop) { $loop->start; $loop->finish } 1 };
    warn "Could not render runner shutdown output: $@" unless $rendered;

    my $remaining = $deadline - time;
    $remaining = 0 if $remaining < 0;

    unless ($self->wait_for_runner_exit($disco, $pid, $remaining)) {
        my $secs = $self->STOP_DEADLINE;
        print STDERR "\nRunner (pid $pid) still running after ${secs}s; it may be wedged, or teardown is still running -- use `yath kill`.\n";
        return 1;
    }

    $self->clean_runner_remains($disco);
    print "\n\nRunner stopped\n\n" unless $self->settings->display->quiet;
    return 0;
}

sub _stop_dead {
    my ($self, $disco) = @_;

    $self->clean_runner_remains($disco);
    print "\n\nRunner was already dead; cleaned up remains\n\n" unless $self->settings->display->quiet;
    return 0;
}

sub _stop_not_live {
    my ($self, $disco) = @_;

    my $pid    = $disco->pid;
    my $reason = $disco->reason // 'unknown';

    # Ambiguous (foreign/inaccessible/unknown, or no pid): stance A never signals and
    # never cleans on ambiguity.
    if (!defined($pid) || $reason eq 'foreign' || $reason eq 'inaccessible' || $reason eq 'unknown') {
        $self->_diag_ambiguous($disco, 'stop');
        return 2;
    }

    # boot/wedged/backlog with a live pid: NO socket attempt (blocking-connect hazard)
    # and NO signal -- stop is graceful only; terminating a wedged runner is `yath kill`.
    print STDERR "\nRunner found but not responding (reason=$reason, pid $pid alive); use `yath kill` to terminate it.\n";
    return 1;
}

# Build + PRIME the shutdown render loop, reusing the same shape `yath watch`
# runs: the engine is a plain runner-output-only Test2::Harness2::Renderer::Base
# (no per-job ordering) with NO renderers/plugins of its own; an
# App::Yath2::RenderLoop::LiveProducer redirects the engine's dispatch into its
# queue (so the engine is a pure source); and an App::Yath2::RenderLoop owns the
# REAL renderers + plugins and the actual sink fan-out. In TAIL mode, priming
# opens the readers positioned at the CURRENT end of the runner stream so later
# iterations render ONLY the teardown output the runner is about to write. Any
# events produced at prime time land in the producer queue and are dispatched on
# the loop's first iterate (order preserved, nothing dropped).
#
# Returns the loop, or undef when runner output is hidden (the caller then skips
# the loop entirely, so the renderers are never stepped or finished -- today's
# hidden-path behavior).
#
# The done() predicate is the irreducible stop-specific bit: the source is
# exhausted once the WRAPPING COLLECTOR has finalized the runner-events stream
# AFTER the runner exited and flushed its teardown ($engine->runner_output_done)
# -- NOT when the inner runner pid dies. The collector outlives that pid by the
# moment it takes to write the final events, and we must read them before run()
# removes the workdir. Inner-pid death only starts a KILL_GRACE crash-grace
# fallback; the shared STOP_DEADLINE (via $deadline_ref) is the hard cap. All
# three arms are verbatim from the previous hand-stepped drain loop.
sub build_shutdown_loop {
    my $self = shift;
    my ($pid, $deadline_ref) = @_;

    my $settings = $self->settings;

    my $show = 1;
    $show = $settings->display->hide_runner_output ? 0 : 1
        if $settings->check_group('display');

    return undef unless $show;

    my $engine = Test2::Harness2::Renderer::Base->new(
        settings           => $settings,
        workdir            => $self->workdir,
        run_id             => gen_uuid(),
        show_runner_output => $show,
        tail               => 1,
    );

    # Best-effort global subscription (LIVE-only): surfaces any teardown aux
    # collector via the transition mirror. If it fails, the monitor is a standalone
    # empty mirror -- the engine still tails the runner's OWN events file by the
    # workdir path, so the runner's teardown output still renders.
    my $sub;
    my $ok  = eval { $sub = $self->client->connect_subscriber; 1 };
    my $err = $@;

    my $monitor = $sub ? $sub->monitor : Test2::Harness2::Runner::Monitor->new;

    my $grace = $self->KILL_GRACE;
    my $dead_at;

    my $producer = App::Yath2::RenderLoop::LiveProducer->new(
        engine     => $engine,
        subscriber => $sub,
        monitor    => $monitor,
        done_check => sub {
            return 1 if $engine->runner_output_done;

            my $alive = $pid && kill(0, $pid);
            $dead_at //= time unless $alive;
            return 1 if $dead_at && (time - $dead_at) > $grace;

            return 1 if $$deadline_ref && time > $$deadline_ref;

            return 0;
        },
    );

    # PRIME: with the producer built (its dispatch_cb installed on the engine), open
    # the tail readers at the current end of the runner stream.
    $sub->poll if $sub;
    $engine->step_runner_output($monitor);

    return App::Yath2::RenderLoop->new(
        renderers => $self->renderers,
        settings  => $settings,
        run_id    => $engine->run_id,
        plugins   => $settings->harness->plugins,
        producer  => $producer,
    );
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::stop - Stop the persistent test runner

=head1 DESCRIPTION

This command will stop a persistent instance, and output any log contents.


=head1 USAGE

    $ yath [YATH OPTIONS] stop [OPTIONS]

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

=head3 Display Options

=over 4

=item --color

=item --no-color

Turn color on, default is true if STDOUT is a TTY.

Can also be set with the following environment variables: C<YATH_COLOR>, C<CLICOLOR_FORCE>

The following environment variables will be set after arguments are processed: C<YATH_COLOR>


=item --hide-runner-output

=item --no-hide-runner-output

Hide output from the runner, showing only test output. (See Also truncate_runner_output)


=item --no-final-table

=item --no-no-final-table

When printing final results, don't use table-style display


=item --no-wrap

=item --no-no-wrap

Do not do fancy text-wrapping, let the terminal handle it


=item --progress

=item --no-progress

Toggle progress indicators. On by default if STDOUT is a TTY. You can use --no-progress to disable the 'events seen' counter and buffered event pre-display


=item -q

=item -qq

=item -qqq..

=item -q=COUNT

=item --quiet

=item --quiet=COUNT

=item --no-quiet

Be very quiet.

Note: Can be specified multiple times, counter bumps each time it is used.


=item --renderer +My::Renderer

=item --renderers +My::Renderer

=item --renderer Renderer=arg1,arg2,...

=item --renderers Renderer=arg1,arg2,...

=item --no-renderers

Specify renderers, (Default: "Formatter=Test2"). Use "+" to give a fully qualified module name. Without "+" "Test2::Harness2::Renderer::" will be prepended to your argument.

Note: Can be specified multiple times


=item -T

=item --show-times

=item --no-show-times

Show the timing data for each job


=item --term-size 80

=item --term-width 80

=item --term-size 200

=item --term-width 200

=item --no-term-width

Alternative to setting $TABLE_TERM_SIZE. Setting this will override the terminal width detection to the number of characters specified.

Can also be set with the following environment variables: C<TABLE_TERM_SIZE>

The following environment variables will be set after arguments are processed: C<TABLE_TERM_SIZE>


=item --truncate-runner-output

=item --no-truncate-runner-output

Only show runner output that was generated after the current command. This is only useful with a persistent runner.


=item -v

=item -vv

=item -vvv..

=item -v=COUNT

=item --verbose

=item --verbose=COUNT

=item --no-verbose

Be more verbose

Note: Can be specified multiple times, counter bumps each time it is used.


=back

=head3 Finder Options

=over 4

=item --changed path/to/file

=item --no-changed

Specify one or more files as having been changed.

Note: Can be specified multiple times


=item --changed-only

=item --no-changed-only

Only search for tests for changed files (Requires a coverage data source, also requires a list of changes either from the --changed option, or a plugin that implements changed_files() or changed_diff())


=item --changes-diff path/to/diff.diff

=item --no-changes-diff

Path to a diff file that should be used to find changed files for use with --changed-only. This must be in the same format as `git diff -W --minimal -U1000000`


=item --changes-exclude-file path/to/file

=item --changes-exclude-files path/to/file

=item --no-changes-exclude-files

Specify one or more files to ignore when looking at changes

Note: Can be specified multiple times


=item --changes-exclude-loads

=item --no-changes-exclude-loads

Exclude coverage tests which only load changed files, but never call code from them. (default: off)


=item --changes-exclude-nonsub

=item --no-changes-exclude-nonsub

Exclude changes outside of subroutines (perl files only) (default: off)


=item --changes-exclude-opens

=item --no-changes-exclude-opens

Exclude coverage tests which only open() changed files, but never call code from them. (default: off)


=item --changes-exclude-pattern '(apple|pear|orange)'

=item --changes-exclude-patterns '(apple|pear|orange)'

=item --no-changes-exclude-patterns

Ignore files matching this pattern when looking for changes. Your pattern will be inserted unmodified into a `$file =~ m/$pattern/` check.

Note: Can be specified multiple times


=item --changes-filter-file path/to/file

=item --changes-filter-files path/to/file

=item --no-changes-filter-files

Specify one or more files to check for changes. Changes to other files will be ignored

Note: Can be specified multiple times


=item --changes-filter-pattern '(apple|pear|orange)'

=item --changes-filter-patterns '(apple|pear|orange)'

=item --no-changes-filter-patterns

Specify a pattern for change checking. When only running tests for changed files this will limit which files are checked for changes. Only files that match this pattern will be checked. Your pattern will be inserted unmodified into a `$file =~ m/$pattern/` check.

Note: Can be specified multiple times


=item --changes-include-whitespace

=item --no-changes-include-whitespace

Include changed lines that are whitespace only (default: off)


=item --changes-plugin Git

=item --changes-plugin +App::Yath2::Plugin::Git

=item --no-changes-plugin

What plugin should be used to detect changed files.


=item --default-at-search ARG

=item --default-at-search=ARG

=item --default-at-search '["json","list"]'

=item --default-at-search='["json","list"]'

=item --no-default-at-search

Specify the default file/dir search when 'AUTHOR_TESTING' is set. Defaults to './xt'. The default AT search is only used if no files were specified at the command line

Note: Can be specified multiple times


=item --default-search ARG

=item --default-search=ARG

=item --default-search '["json","list"]'

=item --default-search='["json","list"]'

=item --no-default-search

Specify the default file/dir search. defaults to './t', './t2', and 'test.pl'. The default search is only used if no files were specified at the command line

Note: Can be specified multiple times


=item --durations file.json

=item --durations http://example.com/durations.json

=item --no-durations

Point at a json file or url which has a hash of relative test filenames as keys, and 'SHORT', 'MEDIUM', or 'LONG' as values. This will override durations listed in the file headers. An exception will be thrown if the durations file or url does not work.


=item --Dt ARG

=item --Dt=ARG

=item --durations-threshold ARG

=item --durations-threshold=ARG

=item --no-durations-threshold

Only fetch duration data if running at least this number of tests. Default (-j value + 1)


=item --exclude-file t/nope.t

=item --exclude-files t/nope.t

=item --no-exclude-files

Exclude a file from testing

Note: Can be specified multiple times


=item --exclude-list file.txt

=item --exclude-lists file.txt

=item --exclude-list http://example.com/exclusions.txt

=item --exclude-lists http://example.com/exclusions.txt

=item --no-exclude-lists

Point at a file or url which has a new line separated list of test file names to exclude from testing. Starting a line with a '#' will comment it out (for compatibility with Test2::Aggregate list files).

Note: Can be specified multiple times


=item --exclude-pattern t/nope.t

=item --exclude-patterns t/nope.t

=item --no-exclude-patterns

Exclude a pattern from testing, matched using m/$PATTERN/

Note: Can be specified multiple times


=item --ext ARG

=item --ext=ARG

=item --extension ARG

=item --extension=ARG

=item --extensions ARG

=item --extensions=ARG

=item --ext '["json","list"]'

=item --ext='["json","list"]'

=item --extension '["json","list"]'

=item --extension='["json","list"]'

=item --extensions '["json","list"]'

=item --extensions='["json","list"]'

=item --no-extensions

Specify valid test filename extensions, default: t and t2

Note: Can be specified multiple times


=item --finder MyFinder

=item --finder +App::Yath2::Finder::MyFinder

=item --no-finder

Specify what Finder subclass to use when searching for files/processing the file list. Use the "+" prefix to specify a fully qualified namespace, otherwise App::Yath2::Finder::XXX namespace is assumed.


=item --maybe-durations file.json

=item --maybe-durations http://example.com/durations.json

=item --no-maybe-durations

Point at a json file or url which has a hash of relative test filenames as keys, and 'SHORT', 'MEDIUM', or 'LONG' as values. This will override durations listed in the file headers. An exception will be thrown if the durations file or url does not work.


=item --no-long

=item --no-no-long

Do not run tests that have their duration flag set to 'LONG'


=item --only-long

=item --no-only-long

Only run tests that have their duration flag set to 'LONG'


=item --rerun

=item --rerun=path/to/log.jsonl

=item --rerun=plugin_specific_string

=item --no-rerun

Re-Run tests from a previous run from a log file (or last log file). Plugins can intercept this, such as YathUIDB which will grab a run UUID and derive tests to re-run from that.


=item --rerun-modes all,failed,missed,passed,retried

=item --no-rerun-modes

=item /^--(no-)?(?^u:rerun-(all|failed|missed|passed|retried)(=.+)?$/

Pick which test categories to re-run. all:     Re-Run all tests from a previous run from a log file (or last log file). Plugins can intercept this, such as YathUIDB which will grab a run UUID and derive tests to re-run from that. failed:  Re-Run failed tests from a previous run from a log file (or last log file). Plugins can intercept this, such as YathUIDB which will grab a run UUID and derive tests to re-run from that. missed:  Run missed tests from a previously aborted/stopped run from a log file (or last log file). Plugins can intercept this, such as YathUIDB which will grab a run UUID and derive tests to re-run from that. passed:  Re-Run passed tests from a previous run from a log file (or last log file). Plugins can intercept this, such as YathUIDB which will grab a run UUID and derive tests to re-run from that. retried: Re-Run retried tests from a previous run from a log file (or last log file). Plugins can intercept this, such as YathUIDB which will grab a run UUID and derive tests to re-run from that.

Note: This will turn on the 'rerun' option. If the --rerun-MODE form is used, you can specify the log file with --rerun-MODE=logfile.

Note: Can be specified multiple times


=item --rerun-plugin Foo

=item --rerun-plugins Foo

=item --rerun-plugin +App::Yath2::Plugin::Foo

=item --rerun-plugins +App::Yath2::Plugin::Foo

=item --no-rerun-plugins

What plugin(s) should be used for rerun (will fallback to other plugins if the listed ones decline the value, this is just used to set an order of priority)

Note: Can be specified multiple times


=item --search ARG

=item --search=ARG

=item --search '["json","list"]'

=item --search='["json","list"]'

=item --no-search

List of tests and test directories to use instead of the default search paths. Typically these can simply be listed as command line arguments without the --search prefix.

Note: Can be specified multiple times


=item --show-changed-files

=item --no-show-changed-files

Print a list of changed files if any are found


=back

=head3 Formatter Options

=over 4

=item --formatter ARG

=item --formatter=ARG

=item --no-formatter

Specify the formatter to use. (Default: "Test2", or "QVF" if --qvf is set)


=item --qvf

=item --no-qvf

[Q]uiet, but [V]erbose on [F]ailure. Hide all output from tests when they pass, except to say they passed. If a test fails then ALL output from the test is verbosely output.


=item --show-job-end

=item --no-show-job-end

Show output when a job ends. (Default: on)


=item --show-job-info

=item --no-show-job-info

Show the job configuration when a job starts. (Default: off, unless -vv)


=item --show-job-launch

=item --no-show-job-launch

Show output for the start of a job. (Default: off unless -v)


=item --show-run-info

=item --no-show-run-info

Show the run configuration when a run starts. (Default: off, unless -vv)


=back

=head3 Git Options

=over 4

=item --git-change-base HEAD^

=item --git-change-base master

=item --git-change-base df22abe4

=item --no-git-change-base

Find files changed by all commits in the current branch from most recent stopping when a commit is found that is also present in the history of the branch/commit specified as the change base.


=back

=head3 Logging Options

=over 4

=item -B

=item --bz2

=item --bzip2

=item --bzip2-log

=item --no-bzip2

Use bzip2 compression when writing the log. This option implies -L. The .bz2 prefix is added to log file name for you


=item -G

=item --gz

=item --gzip

=item --gzip-log

=item --no-gzip

Use gzip compression when writing the log. This option implies -L. The .gz prefix is added to log file name for you


=item -L

=item --log

=item --no-log

Turn on logging


=item --log-dir ARG

=item --log-dir=ARG

=item --no-log-dir

Specify a log directory. Will fall back to the system temp dir.


=item -FARG

=item -F ARG

=item -F=ARG

=item --log-file ARG

=item --log-file=ARG

=item --no-log-file

Specify the name of the log file. This option implies -L.


=item --lff ARG

=item --lff=ARG

=item --log-file-format ARG

=item --log-file-format=ARG

=item --no-log-file-format

Specify the format for automatically-generated log files. Overridden by --log-file, if given. This option implies -L (Default: $YATH_LOG_FILE_FORMAT, if that is set, or else "%!P%Y-%m-%d_%H:%M:%S_%!U.jsonl"). This is a string in which percent-escape sequences will be replaced as per POSIX::strftime. The following special escape sequences are also replaced: (%!P : Project name followed by a ~, if a project is defined, otherwise empty string) (%!U : the unique test run ID) (%!p : the process ID) (%!S : the number of seconds since local midnight UTC)

Can also be set with the following environment variables: C<YATH_LOG_FILE_FORMAT>, C<TEST2_HARNESS_LOG_FORMAT>


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

=head3 Run Options

=over 4

=item -A

=item --author-testing

=item --no-author-testing

This will set the AUTHOR_TESTING environment to true

Can also be set with the following environment variables: C<AUTHOR_TESTING>

The following environment variables will be set after arguments are processed: C<AUTHOR_TESTING>


=item --dbi-profiling

=item --no-dbi-profiling

Use Test2::Plugin::DBIProfile to collect database profiling data


=item -EVAR=VAL

=item -E VAR=VAL

=item --env-var VAR=VAL

=item --no-env-var

Set environment variables to set when each test is run.

Note: Can be specified multiple times


=item --uuids

=item --event-uuids

=item --no-event-uuids

Use Test2::Plugin::UUID inside tests (default: on)


=item -f JSON_STRING

=item -f name:details

=item --fields JSON_STRING

=item --fields name:details

=item --no-fields

Add custom data to the harness run

Note: Can be specified multiple times


=item --input ARG

=item --input=ARG

=item --no-input

Input string to be used as standard input for ALL tests. See also: --input-file


=item --input-file ARG

=item --input-file=ARG

=item --no-input-file

Use the specified file as standard input to ALL tests


=item --io-events

=item --no-io-events

Use Test2::Plugin::IOEvents inside tests to turn all prints into test2 events (default: off)


=item --link 'https://jenkins.work/job/42'

=item --link 'https://travis.work/builds/42'

=item --link 'https://buildbot.work/builders/foo/builds/42'

=item --no-link

Provide one or more links people can follow to see more about this run.

Note: Can be specified multiple times


=item -m ARG

=item -m=ARG

=item -m '["json","list"]'

=item -m='["json","list"]'

=item --load ARG

=item --load=ARG

=item --load-module ARG

=item --load-module=ARG

=item --load '["json","list"]'

=item --load='["json","list"]'

=item --load-module '["json","list"]'

=item --load-module='["json","list"]'

=item --no-load

Load a module in each test (after fork). The "import" method is not called.

Note: Can be specified multiple times


=item -M Module

=item -M Module=import_arg1,arg2,...

=item --loadim Module

=item --load-import Module

=item --loadim Module=import_arg1,arg2,...

=item --load-import Module=import_arg1,arg2,...

=item --no-load-import

Load a module in each test (after fork). Import is called.

Note: Can be specified multiple times


=item --mem-usage

=item --no-mem-usage

Use Test2::Plugin::MemUsage inside tests (default: on)


=item -rARG

=item -r ARG

=item -r=ARG

=item --retry ARG

=item --retry=ARG

=item --no-retry

Run any jobs that failed a second time. NOTE: --retry=1 means failing tests will be attempted twice!


=item --retry-iso

=item --retry-isolated

=item --no-retry-isolated

If true then any job retries will be done in isolation (as though -j1 was set)


=item --id ARG

=item --id=ARG

=item --run-id ARG

=item --run-id=ARG

=item --no-run-id

Set a specific run-id. (Default: a UUID)


=item --stream

=item --use-stream

=item --no-stream

=item --TAP

The TAP format is lossy and clunky. Test2::Harness2 normally uses a newer streaming format to receive test results. There are old/legacy tests where this causes problems, in which case setting --TAP or --no-stream can help.


=item --test-args ARG

=item --test-args=ARG

=item --test-args '["json","list"]'

=item --test-args='["json","list"]'

=item --no-test-args

Arguments to pass in as @ARGV for all tests that are run. These can be provided easier using the '::'  argument separator.

Note: Can be specified multiple times


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

=head3 NO CATEGORY - FIX ME

=over 4

=item --check-reload-state

=item --no-check-reload-state

Abort the run if there are unfixes reload errors and show a confirmation dialogue for unfixed reload warnings.


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

