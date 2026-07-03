package App::Yath2::Command::run;
use strict;
use warnings;

our $VERSION = '2.000000';

use Getopt::Yath;

use Test2::Harness2::Run;
use Test2::Harness2::Util::Queue;
use Test2::Harness2::Util::File::JSON;

use App::Yath2::Pfile;
use App::Yath2::Client;
use App::Yath2::Discovery();
use Test2::Harness2::Util qw/mod2file open_file/;
use Test2::Util::Table qw/table/;

use File::Spec;
use File::Path qw/remove_tree/;
use Time::HiRes qw/time sleep/;
use Errno qw/ESRCH EPERM/;

use Carp qw/croak/;

use parent 'App::Yath2::Command::test';
use Test2::Harness2::Util::HashBase qw/+pfile +banner_printed/;

include_options(
    'App::Yath2::Options::Debug',
    'App::Yath2::Options::Display',
    'App::Yath2::Options::Finder',
    'App::Yath2::Options::Logging',
    'App::Yath2::Options::Logger',
    'App::Yath2::Options::PreCommand',
    'App::Yath2::Options::Run',
);

option_group {group => 'run'} => sub {
    option check_reload_state => (
        type        => 'Bool',
        description => 'Abort the run if there are unfixes reload errors and show a confirmation dialogue for unfixed reload warnings.',
        default     => 1,
    );
};

sub group { 'persist' }

sub summary  { "Run tests using the persistent test runner" }
sub cli_args { '[--] [test files/dirs] [::] [arguments to test scripts] [test_file.t] [test_file2.t="--arg1 --arg2 --param=\'foo bar\'"] [:: --argv-for-all-tests]' }

sub description {
    return <<"    EOT";
This command will run tests through an already started persistent instance. See
the start command for details on how to launch a persistant instance.
    EOT
}

# The persistent `run` runs its harness-client in 'attach' mode: the client
# discovers the long-lived runner (its pid comes from the pfile, attached in
# start_runner), checks liveness with kill(0), and never reaps it. The
# persistent semantics fall out of the mode:
#
#   * The client's terminate_queue is a no-op in attach mode: the run's
#     completeness is signalled by the stop_run request submit_queue already sent
#     (the runner marks this run's queue done). The end_queue the transient path
#     sends would set QUEUE_ENDED and shut the persistent runner down.
sub client_mode { 'attach' }

# The completion test for a run-scoped subscription against a persistent runner:
# the runner keeps its socket open across runs, so we key on this run's announced
# end (harness_run_end) rather than on a socket EOF (which never comes here).
sub subscription_complete {
    my $self = shift;
    my ($sub) = @_;

    # No subscription (runner unreachable): fall back to the runner-liveness test
    # (the client's kill(0) on the persistent pid) so the loop still terminates.
    return $self->client->runner_gone unless $sub;

    return 1 if $sub->run_done;
    return 1 if $sub->closed;
    return 0;
}

sub write_settings_to { }
sub setup_plugins     { }
sub setup_resources   { }
sub teardown_plugins  { }
sub finalize_plugins  { }
sub pfile_params      { () }

sub monitor_preloads { 1 }
sub job_count        { 1 }

sub run {
    my $self = shift;

    my $settings = $self->settings;

    if ($settings->run->check_reload_state) {
        return 255 unless $self->check_reload_state;
    }

    return $self->SUPER::run(@_);
}

sub check_reload_state {
    my $self = shift;

    # Ask the persistent runner for its canonical reload state over
    # runner.socket (App::Yath2::Client). The runner is the reload-state
    # authority.
    my $reload_status = $self->client->reload_state // {};

    my (@out, $errors, $warnings, %seen);
    for my $stage (sort keys %$reload_status) {
        for my $file (keys %{$reload_status->{$stage}}) {
            next if $seen{$file}++;
            my $data = $reload_status->{$stage}->{$file} or next;

            push @out => "\n==== SOURCE FILE: $file ====\n";
            if ($data->{error}) {
                $errors++;
                push @out => $data->{error};
            }

            for (@{$data->{warnings} // []}) {
                push @out => $_;
                $warnings++;
            }
        }
    }
    $errors   //= 0;
    $warnings //= 0;

    return 1 unless @out || $errors || $warnings;

    print <<"    EOT", @out;
*******************************************************************************
* Some source files were reloaded with errors or warnings
* Errors: $errors
* Warnings: $warnings
*******************************************************************************

    EOT

    if ($errors) {
        print <<"        EOT";

*******************************************************************************
Aborting due to reload errors. Please fix the errors so that the modules reload
cleanly, then try the run again. In most cases you will not need to reload the
runner, simply fix the problem with the source file(s) and the runner will
reload them automatically.

        EOT

        return 0;
    }
    elsif ($warnings) {
        print <<"        EOT";

*******************************************************************************
Warnings were encountered when reloading source files, please see the output
above. If these warnings are a problem you should abort this run (control+c)
and correct them before trying again. In most cases you will not need to reload
the runner, simply fix the problem with the source file(s) and the runner will
reload them automatically.

If these warnings are not indicitive of a problem you may continue by pressing
enter/return.

        EOT

        if (-t STDIN) {
            my $ignore = <STDIN>;
            return 1;
        }
        else {
            print STDERR "No TTY detected, aborting run due to warnings...\n";
            return 0;
        }
    }

    return 0;
}

sub init {
    my $self = shift;

    my $settings = $self->settings;
    my $pdata    = $self->pfile_data;

    my $runner_settings = Test2::Harness2::Util::File::JSON->new(name => $pdata->{dir} . '/settings.json')->read();

    for my $prefix (sort keys %{$runner_settings}) {
        next if $settings->check_group($prefix);

        my $new = $settings->group($prefix, 1);
        ${$new->option_ref('from_runner', 1)} = 1;
        for my $key (sort keys %{$runner_settings->{$prefix}}) {
            ${$new->option_ref($key, 1)} = $runner_settings->{$prefix}->{$key};
        }
    }

    return $self->SUPER::init(@_);
}

# The shared persistent-runner discovery object. App::Yath2::Pfile (over
# App::Yath2::Discovery) follows the well-known symlink to the runner socket and
# verifies it accepts a connection (liveness); a missing or dead runner is fatal
# here (run/spawn require a live runner).
sub pfile {
    my $self = shift;
    $self->{+PFILE} //= App::Yath2::Pfile->find($self->settings, $self->pfile_params)
        or die "No persistent harness was found for the current path.\n";
}

sub pfile_data {
    my $self = shift;

    my $pfile = $self->pfile;
    my $data  = $pfile->data;

    # Print the discovery banner exactly once (on first read of the data). The pid
    # can be unknown here (a not-live runner with no/garbled PID file -- #121).
    unless ($self->{+BANNER_PRINTED}++) {
        print "\nFound: $data->{pfile_path}\n";
        print "  PID: " . ($data->{pid} // 'unknown') . "\n";
        print "  Dir: $data->{dir}\n";
    }

    return $data;
}

sub workdir {
    my $self = shift;
    return $self->pfile->workdir;
}

# In attach mode the runner already exists: discover its pid from the pfile and
# hand it to the client (which never reaps it; liveness is a kill(0) on this pid).
sub start_runner {
    my $self = shift;

    my $data = $self->pfile_data;

    return $self->client->attach_runner($data->{pid});
}

# ---------------------------------------------------------------------------
# Shutdown/termination helpers shared by `stop` and `kill` (ticket #121).
#
# These are the ONLY place the persistent-runner termination timing and the
# KILL-safety corroboration predicate live. Every helper takes an explicit
# $seconds where a wait is involved (defaulting to the method-constants below)
# so tests can shrink them. The two timing constants are also env-overridable
# (pure superset: unset => the documented defaults) so the integration
# regression tests run in seconds instead of the full 30s+5s windows.
# ---------------------------------------------------------------------------

# Graceful teardown budget: a TERM to the runner triggers the SAME graceful
# shutdown the socket 'stop' does, so the TERM window inherits stop's teardown
# budget.
sub STOP_DEADLINE { $ENV{YATH_STOP_DEADLINE} // 30 }

# Per-signal grace: post-KILL exit is not up to the process, so a short window
# suffices; also used as the graceful window after kill's end_queue/truncate.
sub KILL_GRACE { $ENV{YATH_KILL_GRACE} // 5 }

# Read a bare numeric pid from a flat PID file WITHOUT caching, so every
# corroboration re-read sees the file as it is right now. Returns the digits, or
# undef when the file is missing/empty/unreadable/garbled.
sub _read_pid_file {
    my ($self, $path) = @_;

    return undef unless defined($path) && -f $path;

    my $pid;
    my $ok  = eval {
        open(my $fh, '<', $path) or die "open '$path': $!";
        $pid = <$fh>;
        close($fh);
        1;
    };
    return undef unless $ok;

    chomp($pid) if defined $pid;
    return undef unless defined($pid) && $pid =~ /^\d+$/;
    return $pid;
}

# Bounded wait for a pid to leave the process table. Returns 1 once kill(0) is
# false (ESRCH / no-longer-signalable => the process is GONE), 0 if it was still
# alive when $seconds elapsed. When handed no pid it re-reads a fresh pid from the
# workdir PID file each poll (#145 contract (c): a booting runner may not have
# written it yet); no pid at all means nothing to wait for => gone.
sub wait_for_runner_exit {
    my ($self, $disco, $pid, $seconds) = @_;

    my $deadline = time + ($seconds // 0);

    while (1) {
        ($pid //= $self->_read_pid_file($disco->pid_file)) if $disco;

        return 1 unless defined($pid) && $pid =~ /^\d+$/ && $pid > 1;
        return 1 unless kill(0, $pid);
        return 0 if time >= $deadline;

        sleep(0.05);
    }
}

# ps-based runner identity (arm of the corroboration predicate). Returns true only
# when the pid's argv positively identifies it as THIS workdir's runner. Empty or
# failed `ps` output is treated as NOT corroborated (fail-safe): we never signal a
# pid we cannot positively identify.
sub runner_identity_ok {
    my ($self, $pid, $disco) = @_;

    return 0 unless defined($pid) && $pid =~ /^\d+$/ && $pid > 1;

    my $args;
    my $ok  = eval { $args = qx{ps -p $pid -o args= 2>/dev/null}; 1 };
    my $err = $@;

    return 0 unless $ok && defined($args) && length($args);

    # Arm 1: the runner rewrites $0 to '[prefix-]yath-runner' (or 'yath-nested-runner')
    # BEFORE the PID file is written, so any pid-file-holding runner carries the name.
    return 1 if $args =~ /\byath-(?:nested-)?runner\b/;

    # Arm 2: platforms whose ps reports the original exec argv ('... runner <workdir> ...').
    my $workdir = $disco ? $disco->workdir : undef;
    return 1
        if defined($workdir)
        && length($workdir)
        && $args =~ /\brunner\b/
        && index($args, $workdir) >= 0;

    return 0;
}

# The KILL-safety corroboration predicate C(pid), re-evaluated immediately before
# EVERY signal. Returns 'ok' (safe to signal), 'gone' (already ESRCH -- skip the
# signal, success), or 'refuse:<why>' (a claim we could NOT turn into an identity --
# NO signal is ever sent). $ack_pid, when defined, is a ping-ack's self-reported pid
# (exact identity). See the ticket's KILL-safety proof.
sub corroborate_runner {
    my ($self, $disco, $pid, $ack_pid) = @_;

    # (1) FRESH re-read of the workdir PID file must still name exactly $pid, and
    # $pid > 1 (the >1 guard closes the undef/garbled-pid => kill($sig,0) own-process-
    # group catastrophe as well as the workdir-tie/freshness check).
    my $fresh = $self->_read_pid_file($disco->pid_file);
    return "refuse:workdir PID file no longer names pid " . (defined($pid) ? $pid : 'undef')
        unless defined($fresh)
        && $fresh =~ /^\d+$/
        && defined($pid)
        && $pid =~ /^\d+$/
        && $fresh == $pid
        && $pid > 1;

    # (2) liveness. ESRCH => already gone (success, no signal needed). EPERM => a
    # process exists but is not ours to signal (refuse). Any other errno: not
    # signalable => treat as gone.
    unless (kill(0, $pid)) {
        my $errno = $! + 0;
        return 'gone'                                                       if $errno == ESRCH;
        return "refuse:pid $pid exists but is not ours to signal (EPERM)"   if $errno == EPERM;
        return 'gone';
    }

    # (3) identity: an exact ping-ack pid, OR a positive ps identity match.
    return 'ok' if defined($ack_pid) && "$ack_pid" =~ /^\d+$/ && $ack_pid == $pid;
    return 'ok' if $self->runner_identity_ok($pid, $disco);

    return "refuse:could not confirm pid $pid is the runner (identity unverified)";
}

# The kill-only escalation ladder: corroborate -> TERM -> bounded wait -> re-
# corroborate -> KILL -> bounded wait -> judge. Returns 'killed' (confirmed gone at
# some point => clean + exit 1), 'refuse:<why>' (corroboration failed => NO signal,
# NO clean, exit 2), or 'survived' (still alive KILL_GRACE after SIGKILL => exit 2,
# NO clean). "Unconditional" governs WHEN (signals follow the graceful attempt),
# corroboration governs WHOM.
sub escalate_kill_runner {
    my ($self, $disco, $pid, $ack_pid) = @_;

    my $c = $self->corroborate_runner($disco, $pid, $ack_pid);
    return 'killed' if $c eq 'gone';
    return $c       if $c =~ /^refuse:/;

    kill('TERM', $pid);
    return 'killed' if $self->wait_for_runner_exit($disco, $pid, $self->STOP_DEADLINE);

    # Identity re-proven at signal time, not probe time.
    $c = $self->corroborate_runner($disco, $pid, $ack_pid);
    return 'killed' if $c eq 'gone';
    return $c       if $c =~ /^refuse:/;

    kill('KILL', $pid);
    return 'killed' if $self->wait_for_runner_exit($disco, $pid, $self->KILL_GRACE);

    return 'survived';
}

# Remove the remains of a runner that has been CONFIRMED gone (ESRCH) -- reachable
# only after a deadness observation (see the ticket's cleanup-not-racing-live
# proof). The discovery link is removed through #145's flock mutator protocol
# (clean_if_mine: re-readlink + successor-pid guard + euid check + -l-guarded
# unlink); the workdir remove_tree is then gated on a FRESH re-read of workdir/PID:
# absent, our (now-dead) pid, or a dead pid => remove; a DIFFERENT LIVE pid means a
# successor claimed the pinned workdir => skip BOTH (fail-safe: tidiness lost, never
# a live runner's workdir).
sub clean_runner_remains {
    my ($self, $disco) = @_;

    my $link       = $disco->link;
    my $workdir    = $disco->workdir;
    my $own_socket = defined($workdir) ? File::Spec->catfile($workdir, 'runner.socket') : undef;
    my $our_pid    = $disco->pid;

    App::Yath2::Discovery->new(link => $link)->clean_if_mine($own_socket, $our_pid)
        if defined($link) && defined($own_socket);

    return unless defined($workdir) && length($workdir) && -d $workdir;

    my $wpid = $self->_read_pid_file(File::Spec->catfile($workdir, 'PID'));
    return
        if defined($wpid)
        && $wpid =~ /^\d+$/
        && (!defined($our_pid) || $wpid != $our_pid)
        && kill(0, $wpid);

    remove_tree($workdir, {safe => 1, keep_root => 0});
    return;
}

# Diagnostic for an AMBIGUOUS not-live runner (foreign/inaccessible/unknown, or no
# pid): stance A never signals and never cleans on ambiguity. Prints the state and
# the manual cleanup commands. $cmd is 'stop' or 'kill'.
sub _diag_ambiguous {
    my ($self, $disco, $cmd) = @_;

    my $pid     = $disco->pid     // 'unknown';
    my $state   = $disco->state   // 'unknown';
    my $reason  = $disco->reason  // 'unknown';
    my $workdir = $disco->workdir // 'unknown';
    my $link    = $disco->link;

    print STDERR <<"    EOT";

Could not $cmd the persistent runner: its state is ambiguous, and yath will not
signal or clean up on ambiguity.
  state:   $state
  reason:  $reason
  pid:     $pid
  workdir: $workdir
  link:    $link

If you are certain no runner is using that workdir, remove them by hand:
  rm -f '$link'
  rm -rf '$workdir'
    EOT

    return;
}

# Diagnostic for a pid that FAILED corroboration (a possibly-recycled pid): NO
# signal was sent and nothing was cleaned. Prints the pid, its ps line, and the
# manual commands. $cmd is 'kill' (only kill signals).
sub _diag_refuse {
    my ($self, $disco, $pid, $why, $cmd) = @_;

    my $workdir = $disco->workdir // 'unknown';
    my $link    = $disco->link;

    my $psline = '';
    eval { $psline = qx{ps -p $pid -o args= 2>/dev/null}; 1 };
    chomp($psline) if defined $psline;
    $psline = '(unavailable)' unless defined($psline) && length($psline);

    print STDERR <<"    EOT";

Refusing to $cmd pid $pid: $why
The pid named by the workdir PID file could not be corroborated as the runner (it
may be a recycled pid now belonging to an unrelated process), so NO signal was
sent and nothing was cleaned up.
  pid:     $pid
  ps:      $psline
  workdir: $workdir
  link:    $link

If you have confirmed this pid is a leftover runner, terminate it by hand:
  kill -TERM $pid   # then, if it survives: kill -KILL $pid
  rm -f '$link'
  rm -rf '$workdir'
    EOT

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::run - Run tests using the persistent test runner

=head1 DESCRIPTION

This command will run tests through an already started persistent instance. See
the start command for details on how to launch a persistant instance.


=head1 USAGE

    $ yath [YATH OPTIONS] run [OPTIONS]

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

