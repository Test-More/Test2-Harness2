package Test2::Harness2::Runner;
use strict;
use warnings;

our $VERSION = '2.000000';

use File::Spec();

use Carp qw/confess croak/;
use POSIX qw/:sys_wait_h/;
use Time::HiRes qw/sleep time/;

use Test2::Harness2::Util qw/clean_path file2mod mod2file parse_exit write_file_atomic publish_discovery_link process_includes chmod_tmp write_file collector_exit_code runner_events_file socket_reporter mono_time/;
use Test2::Harness2::Util::Queue();
use Test2::Harness2::Util::JSON(qw/encode_json/);
use Test2::Harness2::Util::SubReaper qw/acquire_subreaper subreaper_supported/;

use Test2::Harness2::Runner::Constants;

use Test2::Harness2::Runner::Run();
use Test2::Harness2::Runner::Job();
use Test2::Harness2::Runner::Spawn();
use Test2::Harness2::Runner::State();
use Test2::Harness2::Runner::Preloader();
use Test2::Harness2::Runner::Monitor();
use Test2::Harness2::Runner::Watchdog();
use Test2::Harness2::Runner::StatusReport();

use Test2::Harness2::Runner::Role::Service::Handlers();
use Test2::Harness2::Runner::Role::Scheduler();

use Test2::Harness2::Plugin();    # $AUX_PIDS registry + run_collected/shellcall

use parent 'Test2::Harness2::IPC';
use Test2::Harness2::Util::HashBase(
    # Fields from settings
    qw{
        <job_count <slots_per_job

        <includes <tlib <lib <blib
        <unsafe_inc

        <use_fork <preloads <preload_threshold <switches
        <restrict_reload

        <cover

        <event_timeout <post_exit_timeout <resource_timeout

        <resources

        <nytprof

        <reload
    },
    # From Construction
    qw{
        <dir <settings <fork_job_callback <monitor_preloads
        <jobs_todo <dump_depmap <persist
    },
    # Other
    qw {
        +preloader
        +state

        <stage
        <signal

        +last_timeout_check
        +timeout_signaled
        +run_reached_timeout
        <tmp_dir

        <rootpid

        +monitor
        +watchdog

        +announced_runs
        +active_run

        +job_pids

        +plugins
        +aux_pids

        +preload_root_pid
        +preload_root_reaped
        +reported_stage_data
        +preload_root_hosts

        +sampler_pid
    },
);

# Stale-incarnation stage reports are rejected by connection-currency in the
# runner's stage-report handlers (the registered `preload-<stage>` peer connection
# IS the live incarnation), so there is no wire-generation counter (bloat #3). A
# preload-root crash is fatal -- the runner does not respawn it (bloat #3, §4.2) --
# so there is no respawn counter either.

use Role::Tiny::With;
with 'Test2::Harness2::Role::Service';
with 'Test2::Harness2::Runner::Role::Service::Handlers';
with 'Test2::Harness2::Runner::Role::Scheduler';

sub job_class { 'Test2::Harness2::Runner::Job' }

# Launch the runner process under its own non-test collector
# (ARCH 4.2: "Test2::Harness2::Runner->start (or equivalent) launches the runner
# process under a non-test collector"). This is the single shared collector-wrap
# the transient (`yath test`) AND persistent (`yath start`) paths both use, so
# the runner's stdout/stderr/exit become first-class timestamped events in
# runner-events.jsonl.zst -- the same wire format and reader path as job/stage
# events -- instead of flat output.log/error.log files.
#
# Returns a coderef suitable as the `command` for a fork-exec spawn (IPC->spawn
# or run_cmd): it runs in the already-forked child, which becomes the collector
# PARENT and never returns -- it forks+execs the real runner (capturing its
# streams), records the full stream, and POSIX::_exit()s with the runner child's
# verdict (collector_exit_code) so IPC's runner-death detection is unchanged.
sub start_collected {
    my $class = shift;
    my ($cmd, $events_file) = @_;

    return sub {
        require Test2::Collector;
        require Test2::Collector::Recorder::Zstd;

        # The collector captures the runner child's OWN stdout/stderr through its
        # own pipes into the events file, so the collector PARENT's inherited
        # stdout/stderr are unused. Detach them to /dev/null up front: this child
        # is invoked by run_cmd BEFORE run_cmd's own stdout/stderr swap, so a
        # daemon collector parent would otherwise hold the caller's pipe (e.g.
        # `yath start`'s captured stdout) open for the runner's whole lifetime,
        # hanging a caller that reads to EOF.
        open(\*STDOUT, '>', File::Spec->devnull) or die "Could not detach STDOUT: $!";
        open(\*STDERR, '>', File::Spec->devnull) or die "Could not detach STDERR: $!";

        # WATCH-PARENT-EXEMPT: this collector's child IS the runner, so there is no
        # runner to watch (ARCHITECTURE.md §4.1 exempts the runner-wrap). It exits
        # when the runner exits (child EOF), which is the normal finalize path.
        my $info = Test2::Collector::collect(
            is_test  => 0,
            name     => 'runner',
            exec     => [@$cmd],
            recorder => Test2::Collector::Recorder::Zstd->new(file => $events_file),
        );
        POSIX::_exit(collector_exit_code($info));
    };
}

# The runner service is the canonical 'runner.socket' in the workdir (ARCH 4.2,
# 5.3). 'workdir' and 'name' satisfy Test2::Harness2::Role::Service.
sub name    { 'runner' }
sub workdir { my $self = shift; return $self->{+DIR} }

# The runner is the canonical 'runner' service (runner.socket); Role::Service's
# default service_name (== name) already returns 'runner', so there is nothing to
# override. A preload stage's own service_name ('preload-<stage>') lives in
# Test2::Harness2::Preload::Host, the independent stage-host class (ticket #22).

our $RUNNER_PID;

sub init {
    my $self = shift;

    # The runner is always the root scheduler process (ticket #22: the stage host
    # is now a separate class, Test2::Harness2::Preload::Host, so a Runner is never
    # built with rootpid != $$). rootpid is therefore this process; it is conveyed
    # down as runner_pid / watch_parent_pid so resource accounting and the
    # collectors' parent-watch key on the runner. $RUNNER_PID tracks it for resource
    # accounting.
    $self->{+ROOTPID} //= $$;
    $RUNNER_PID = $self->{+ROOTPID};

    $self->{+ANNOUNCED_RUNS} = {};
    $self->{+JOB_PIDS}       = {};

    croak "'dir' is a required attribute"      unless $self->{+DIR};
    croak "'settings' is a required attribute" unless $self->{+SETTINGS};

    my $dir = clean_path($self->{+DIR});

    croak "'$dir' is not a valid directory"
        unless -d $dir;

    $self->{+DIR} = $dir;

    $self->{+HANDLERS}->{HUP} = sub {
        my $sig = shift;

        # The runner is purely the scheduler/orchestrator: it holds no preloaded
        # interpreter state and does not self-restart. When a preload-root is up,
        # reload lives entirely in the preload tree. Route the reload to the
        # base/default stage's LIVE channel -- the one stage connection the runner
        # services throughout a run -- not the preload-root's handshake channel,
        # which is dormant mid-run (the preload-root is blocked in its stage host and
        # only services that channel at post-run idle, so a reload sent there sits
        # unread, or fires late during shutdown). The base/default stage runs in the
        # preload-root process, so it owns the respawn jump frame; it translates the
        # reload into the in-run respawn of the whole tree.
        if ($self->{+PRELOAD_ROOT_PID}) {
            my $id = $self->_preload_root_stage_identity or return;
            # One-way: reload_root's handler returns undef (no reply), so skip the
            # PENDING insert to avoid a daemon-lifetime leak. (#134 finding 106)
            $self->service_send($id, 'reload_root', want_reply => 0);
            return;
        }

        # No preload-root: a no-preload run has nothing to reload, so HUP is a no-op
        # (a no-preload persistent runner must be restarted to pick up code changes).
        return;
    };

    my $tmp_dir = File::Spec->catdir($self->{+DIR}, 'tmp');
    unless (-d $tmp_dir) {
        mkdir($tmp_dir) or die "Could not create temp dir: $!";
        chmod_tmp($tmp_dir);
    }
    $self->{+TMP_DIR} = $tmp_dir;

    my $have_job_limiter = 0;
    for my $res (@{$self->{+RESOURCES}}) {
        require(mod2file($res)) unless ref($res);
        $have_job_limiter++ if $res->job_limiter;
    }

    unless ($have_job_limiter) {
        require Test2::Harness2::Runner::Resource::JobCount;
        unshift @{$self->{+RESOURCES}} => 'Test2::Harness2::Runner::Resource::JobCount';
    }

    $self->SUPER::init();
}

sub preloader {
    my $self = shift;

    $self->{+PRELOADER} //= Test2::Harness2::Runner::Preloader->new(
        dir             => $self->{+DIR},
        persist         => $self->{+PERSIST},
        preloads        => $self->preloads,
        monitor         => $self->{+MONITOR_PRELOADS},
        restrict_reload => $self->{+RESTRICT_RELOAD},
        dump_depmap     => $self->{+DUMP_DEPMAP},
        reload          => $self->{+RELOAD},

        # The root runner pid, so each stage collector watches it and
        # self-terminates if the runner dies (ARCHITECTURE.md §4.1).
        runner_pid => $self->{+ROOTPID},

        below_threshold => ($self->{+PRELOAD_THRESHOLD} && $self->{+JOBS_TODO} && $self->{+PRELOAD_THRESHOLD} > $self->{+JOBS_TODO}) ? 1 : 0,
    );
}

sub state {
    my $self = shift;

    my $settings = $self->settings;

    # When the preload-root hosts the stages this runner is
    # scheduler-only and holds NO preloader. State resolves a task's stage entirely
    # client-side from the test's preload directives (no_preload / require_preload /
    # preload_list) against the reported stage map -- there is no file_stage resolver
    # and no round-trip to a stage. set_stage_data refreshes the stage map on the
    # built State when the map arrives.
    if ($self->_preload_root_hosts_stages) {
        $self->{+STATE} //= Test2::Harness2::Runner::State->new(
            workdir   => $self->{+DIR},
            stage_map => $self->reported_stage_data // {},
            resources => [map { $_->new(settings => $settings) } @{$self->{+RESOURCES}}],
            settings  => $settings,
        );
        return $self->{+STATE};
    }

    my $preloader = $self->preloader;

    $self->{+STATE} //= Test2::Harness2::Runner::State->new(
        workdir   => $self->{+DIR},
        preloader => $preloader,
        resources => [map { $_->new(settings => $settings) } @{$self->{+RESOURCES}}],
        settings  => $settings,
    );

    # The runner is the sole writer/reader of its scheduling state: stages receive
    # work over sockets (on both the transient and persistent paths) and the
    # run/spawn/abort/status/resources commands submit + query over runner.socket.
    # The State applies every action in-process.
    return $self->{+STATE};
}

sub check_timeouts {
    my $self = shift;

    return unless $self->settings->runner->use_timeout;

    my $now = time;

    # Check only once per second, that is as granular as we get. Also the check is not cheep.
    return if $self->{+LAST_TIMEOUT_CHECK} && $now < (1 + $self->{+LAST_TIMEOUT_CHECK});

    # The per-test silence and lifetime timeouts are now enforced by the
    # Test2-Collector collector parent itself (via collect(silence_timeout =>
    # ..., lifetime_timeout => ...)): it kills the test child's process group,
    # records the timeout in events.jsonl.zst, and exits. The runner no longer
    # tracks per-job output activity or writes event_timeout/post_exit_timeout
    # marker files.
    #
    # What remains here is a fallback for a collector PARENT that should have
    # exited but has not: once a job process has been reaped (it is in WAITING)
    # we give it a grace window, then escalate TERM -> KILL so a wedged
    # collector cannot hang the run.
    my $grace = $self->{+POST_EXIT_TIMEOUT} || 60;

    my $signaled = $self->{+TIMEOUT_SIGNALED} //= {};

    # Drop entries for pids that are no longer live, so a future job that reuses
    # a pid does not inherit a stale "already TERMed, escalate to KILL" flag.
    delete $signaled->{$_} for grep { !$self->{+PROCS}->{$_} } keys %$signaled;

    for my $pid (keys %{$self->{+PROCS}}) {
        my $job = $self->{+PROCS}->{$pid};
        next unless $job->isa('Test2::Harness2::Runner::Job');

        my $waiting = $self->{+WAITING}->{$pid} or next;
        my $since   = $waiting->[1] // $now;
        next unless ($now - $since) > $grace;

        my $kill = $signaled->{$pid}++;

        my $sigmap = $self->SIG_MAP;
        my $sig    = $kill ? $sigmap->{'KILL'} : $sigmap->{'TERM'};
        $sig = "-$sig" if $self->USE_P_GROUPS;

        print STDERR "$$ $0 " . $job->file . " collector process-group did not fully exit after the collector was reaped, sending " . ($kill ? 'SIGKILL' : 'SIGTERM') . " to $pid...\n";

        $self->{+RUN_REACHED_TIMEOUT} //= {};
        $self->{+RUN_REACHED_TIMEOUT}->{$job->task->{job_id}} = $pid;

        kill($sig, $pid);
    }

    $self->{+LAST_TIMEOUT_CHECK} = time;
}

sub stop {
    my $self = shift;

    $self->check_for_fork;

    if (keys %{$self->{+PROCS}}) {
        print "$$ $0 Sending all child processes the TERM signal...\n";
        # Send out the TERM signal
        $self->killall($self->{+SIGNAL} // 'TERM');
        $self->wait(all => 1, timeout => 5);
    }

    # Time to get serious
    if (keys %{$self->{+PROCS}}) {
        local $?;
        print STDERR "$$ $0 Some child processes are refusing to exit, sending KILL signal...\n";
        print("$$ $0 == $_ " . waitpid($_, WNOHANG) . "\n") for keys %{$self->{+PROCS}};
        $self->killall('KILL');
    }

    $self->SUPER::stop();
}

sub handle_sig {
    my $self = shift;
    my ($sig) = @_;

    return if $self->{+SIGNAL};

    return $self->{+HANDLERS}->{$sig}->($sig) if $self->{+HANDLERS}->{$sig};

    $self->{+SIGNAL} = $sig;
    die "Runner caught SIG$sig. Attempting to shut down cleanly...\n";
}

sub all_libs {
    my $self = shift;

    my @out;

    push @out => @{$self->{+INCLUDES}} if $self->{+INCLUDES};

    push @out => 't/lib' if $self->{+TLIB};
    push @out => 'lib'   if $self->{+LIB};

    if ($self->{+BLIB}) {
        push @out => 'blib/lib';
        push @out => 'blib/arch';
    }

    return @out;
}

# Mark the runner as a child subreaper so it owns reaping for the whole process
# tree (detached preload collectors re-parent here). All syscall/platform logic
# lives in Test2::Harness2::Util::SubReaper -- never inlined here. A failed or
# unsupported acquire is non-fatal: detached collectors then re-parent to init and
# the EOF-based completion decision is unaffected (ARCHITECTURE.md §5.4).
sub become_subreaper {
    my $self = shift;

    return 0 unless subreaper_supported();

    unless (acquire_subreaper()) {
        warn "$$ $0 could not acquire child-subreaper status: $!\n";
        return 0;
    }

    return 1;
}

sub process {
    my $self = shift;

    # Become the child subreaper for the whole process tree BEFORE any collector
    # is forked, so every preload-spawned collector that double-forks and detaches
    # re-parents up to THIS runner (the nearest subreaper ancestor) rather than to
    # the preload tree. Only the runner acquires this -- the preload-root/host and
    # forked stages must not, or a detached collector would stop at them. On an
    # unsupported platform this is a graceful no-op and detached collectors
    # re-parent to init; the completion decision rides EOF either way
    # (ARCHITECTURE.md §5.4). The reaping is pure zombie cleanup.
    $self->become_subreaper;

    @INC = process_includes(
        list            => [@{$self->settings->harness->dev_libs}, $self->all_libs],
        include_dot     => $self->unsafe_inc,
        include_current => 1,
        clean           => 1,
    );

    # The workdir PID file names the runner.
    my $pidfile = File::Spec->catfile($self->{+DIR}, 'PID');
    write_file_atomic($pidfile, "$$");

    # Propagate the workdir to every child (collectors, stages, jobs) so they can
    # locate runner.socket without hardcoded assumptions (ARCH 5.3). Setting it in
    # the runner process means forked stages inherit it directly, and the
    # Test2::Collector child_env merge carries it on into test children; jobs also
    # set it explicitly in their curated env (Runner::Job::env_vars).
    $ENV{T2_HARNESS_WORKDIR} = $self->{+DIR};

    # Bind runner.socket and run the accept/request loop coexisting with the
    # run loop. The scheduler is an in-runner object ticked each service-loop
    # iteration. The transient `yath test` command submits its run and tasks
    # over this socket, which the request handlers fold into the in-process
    # State. The transient path does not write queue.jsonl/jobs.jsonl; they
    # remain only for the gated persistent path.
    $self->start_service;

    # Publish the discovery symlink LAST, from the runner itself, immediately after
    # runner.socket is bound (fork A of ticket #145). The ordering invariant is
    # load-bearing for the race proof: the PID file (438) happens-before the socket
    # bind (454) happens-before this publish, all in this one process -- so any
    # racing cleaner's locked deadness re-check sees this runner's live PID and never
    # unlinks the just-published link, and a daemon stays discoverable even if `start`
    # died before it could publish. publish_discovery_link takes the shared publisher
    # lock so it serializes against a concurrent cleaner.
    if (my $persist = $self->{+PERSIST}) {
        my $socket = File::Spec->catfile($self->{+DIR}, 'runner.socket');
        my $ok = eval { publish_discovery_link($socket, $persist); 1 };
        warn "Could not publish discovery symlink '$persist' -> '$socket': $@" unless $ok;
    }

    # Plugin setup() runs HERE, in the runner, after runner.socket is
    # bound -- so a plugin's aux work (shellcall / run_collected) reports to the
    # socket as collector events instead of flat aux_logs files, and any aux
    # process is a runner child that dies with the runner. teardown() runs below,
    # after the run loop, before stop().
    $self->setup_plugins;

    # Stand up the separate preload-root process (it dials this socket and
    # handshakes); it forks the stages and launches the tests.
    $self->spawn_preload_root if $self->_preload_root_wanted;

    # Stand up the always-on system-load sampler (it dials this socket and pushes
    # load snapshots); spawned whenever the runner runs, independent of whether a
    # throttling resource was requested, so its transitions are always logged.
    $self->spawn_sampler;

    $self->start();

    my $ok  = eval { $self->run_scheduler_only(); 1 };
    my $err = $@;

    warn $err unless $ok;

    # G2 (#134 finding 14, defense-in-depth): if a run_cmd fork-child somehow
    # unwound past its G1 eval and into THIS eval, $$ is the transient child's pid,
    # not the runner's. It must NOT execute the wind-down below (stop the real
    # preload-root/sampler, kill the real aux pids, unlink runner.socket, wait on
    # subscribers, close the service) -- all of which mutate parent-owned OS state.
    # POSIX::_exit(255) immediately, bypassing every cleanup and END block.
    unless ($$ == $self->{+ROOTPID}) {
        print STDERR "$$ $0: fork child escaped into runner wind-down, aborting\n";
        POSIX::_exit(255);
    }

    # Tear the preload-root down before plugin teardown/stop so it is
    # reaped while the runner is still servicing its socket.
    $self->stop_preload_root;

    # Reap the sampler before this process exits. The sampler's collector inherited
    # this runner's stdout/stderr write ends, so until it is gone the runner's own
    # collector never sees EOF on those pipes (and would stall on its orphan
    # timeout). Reaped while we still service the socket so its stop is delivered.
    $self->stop_sampler;

    $self->teardown_plugins;

    $self->stop();

    # The transient command's render completion is the runner closing
    # this socket. Before we close, drain any in-flight transition frames a job
    # collector flushed late (a stage's last job whose final_state lands during
    # wind-down) so they are folded + forwarded to the subscriber AND so a late
    # collector connection EOF still runs the completion decision (§5.4). By now
    # stop() has reaped every child, so a few non-blocking service passes capture
    # the remainder. The watchdog already aborted any job still tracked as running,
    # and the EOF decision is fire-once, so this cannot double-decide. Transient
    # only; the gated persistent path has the gatherer.
    $self->_drain_transitions unless $self->{+PERSIST};

    # Persistent path: before tearing down runner.socket (which evicts every
    # subscriber) and letting App::Yath2::Command::runner's exit guard remove_tree
    # the workdir, bounded-wait for the run-SCOPED subscribers to disconnect. A DB
    # logger is a run-scoped subscriber (db spec §7e) that imports the per-run
    # events.jsonl.zst artifact blobs out of the workdir, then disconnects; deferring
    # cleanup until it drops keeps the blobs alive until its import finishes. GLOBAL
    # subscribers (a persistent `yath watch` / dashboard with no run_id) may stay
    # connected indefinitely and must NOT gate cleanup, so they are excluded. On the
    # transient path the runner never removes the workdir (the `test` command does,
    # after its own render), so this wait is persistent-only.
    $self->_wait_for_run_subscribers if $self->{+PERSIST};

    # The runner closes runner.socket here (its close is the transient command's
    # completion signal).
    $self->close_service;

    return $self->{+SIGNAL} ? 128 + $self->SIG_MAP->{$self->{+SIGNAL}} : $ok ? 0 : 1;
}

# Final non-blocking sweep of the service socket so transitions that
# arrived after the run loop ended are folded into the monitor and forwarded to
# the subscriber before the socket closes (the command's completion signal).
sub _drain_transitions {
    my $self = shift;

    # Drain until the service socket is quiet, bounded by an overall deadline so
    # a peer that never goes silent cannot hang the close. Each pass services
    # whatever is pending, then peeks the select set: once a pass leaves nothing
    # readable (no pending connection on the listener, no data on any conn) the
    # in-flight frames are folded and we stop early rather than spinning out the
    # whole budget.
    my $deadline = mono_time + 0.5;    # pure interval -> monotonic (#134 finding 104)
    while (1) {
        $self->service_io;

        last if mono_time >= $deadline;

        my $sel = $self->{service_select} or last;
        last unless $sel->can_read(0);

        Time::HiRes::sleep(0.01);
    }

    return;
}

# How long (seconds) the persistent runner will bounded-wait for run-scoped
# subscribers to disconnect before it gives up and cleans the workdir anyway. A
# package var so it can be tuned/overridden without an option (the ticket asks for
# a "sane timeout", not a user knob). DB loggers are normally fast; this is the
# safety bound against a wedged subscriber that never drops.
our $SUBSCRIBER_DRAIN_TIMEOUT = 60;

# Count the subscribers that asked to GATE workdir cleanup: run-scoped (defined
# run_id) AND drain_gate (a DB logger that subscribed with drain_gate=>1, db spec
# §7e). Excluded: GLOBAL subscribers (run_id => undef -- a `yath watch` / dashboard;
# may stay connected indefinitely) AND plain render subscribers (the `test`/`run`
# command's own subscription -- it never disconnects until the runner closes the
# socket, so gating on it would deadlock the shutdown wait). Only a logger
# voluntarily disconnects after importing, so only a logger should gate.
sub _run_scoped_subscriber_count {
    my $self = shift;

    my $subs = $self->{service_subs} or return 0;

    my $count = 0;
    for my $sub (values %$subs) {
        next unless defined $sub->{run_id} && $sub->{drain_gate};
        my $conn = $sub->{conn};
        next if $conn && $conn->closed;
        $count++;
    }

    return $count;
}

# Persistent-runner shutdown gate (db spec §7e / "Gemini-2" bounded-wait). Before
# the workdir holding the per-run events.jsonl.zst artifact blobs is removed, give
# the run-scoped subscribers (DB loggers) time to finish importing and disconnect.
# Service the socket each pass so closed subscriber connections are evicted from
# service_subs (via _drop_conn), then re-check the run-scoped count. Bounded by
# $SUBSCRIBER_DRAIN_TIMEOUT: on timeout proceed with cleanup and WARN rather than
# hang forever. GLOBAL subscribers are excluded from the count so they never block.
sub _wait_for_run_subscribers {
    my $self = shift;

    # Nothing to gate on: no run-scoped subscriber connected (transient `yath test`
    # never gets here; a persistent runner with only `watch`/no subscribers exits
    # immediately).
    return unless $self->_run_scoped_subscriber_count;

    my $deadline = mono_time + $SUBSCRIBER_DRAIN_TIMEOUT;    # pure interval -> monotonic (#134 finding 104)
    while (1) {
        # Service IO so a subscriber that just closed its end is drained + dropped
        # from service_subs this pass, and so any final frames still reach it.
        $self->service_io;

        last unless $self->_run_scoped_subscriber_count;

        if (mono_time >= $deadline) {
            my $left = $self->_run_scoped_subscriber_count;
            warn "$$ $0: timed out after ${SUBSCRIBER_DRAIN_TIMEOUT}s waiting for $left run-scoped subscriber(s) (e.g. a DB logger) to disconnect; cleaning the workdir anyway -- a log import may be incomplete\n";
            last;
        }

        Time::HiRes::sleep(0.01);
    }

    return;
}

# Plugin setup/teardown run in the runner (not the command). The command
# serializes plugins to bare class names, so the runner reconstructs the SAME
# instances from the resolved specs (Class or Class=arg1,arg2) the command stashed
# in settings->harness->plugin_specs. Loading App::Yath2::Plugin::* is user-driven
# (the -p the user passed), which the dependency rule permits.
sub plugins {
    my $self = shift;
    return $self->{+PLUGINS} //= $self->_build_plugins;
}

sub _build_plugins {
    my $self = shift;

    my $harness = $self->settings->harness;
    my $specs   = $harness->check_option('plugin_specs') ? $harness->plugin_specs : undef;
    $specs //= [];

    my (%seen, @plugins);
    for my $spec (@$specs) {
        my ($class, $args) = split /=/, $spec, 2;
        next if $seen{$class}++;
        my @args = defined($args) ? (split /,/, $args) : ();

        my $file = mod2file($class);
        my $ok   = eval { require $file unless $INC{$file}; 1 };
        unless ($ok) {
            warn "$$ $0 Runner could not load plugin '$class': $@";
            next;
        }

        push @plugins => $class->can('new') ? $class->new(@args) : $class;
    }

    return \@plugins;
}

# Run each plugin's setup() / teardown() in the runner root. A run_collected aux
# process registers its pid through the Test2::Harness2::Plugin::AUX_PIDS package
# registry we localize here, so the runner can stop it at teardown; it is
# deliberately NOT in {+PROCS} (so it never blocks the runner's wait(all=>1)).
sub setup_plugins {
    my $self = shift;

    $self->{+AUX_PIDS} //= [];
    local $Test2::Harness2::Plugin::AUX_PIDS = $self->{+AUX_PIDS};
    $_->setup($self->settings) for @{$self->plugins};

    return;
}

sub teardown_plugins {
    my $self = shift;

    $self->{+AUX_PIDS} //= [];
    {
        local $Test2::Harness2::Plugin::AUX_PIDS = $self->{+AUX_PIDS};
        $_->teardown($self->settings) for reverse @{$self->plugins};
    }

    $self->stop_aux;

    return;
}

# Stop every aux process started under this runner (a run_collected daemon). They
# are not in {+PROCS}, so signal + reap them directly; their collector also watches
# the runner pid (ARCHITECTURE.md §4.1) as the fallback if the runner dies hard.
sub stop_aux {
    my $self = shift;
    my $pids = $self->{+AUX_PIDS} or return;
    return unless @$pids;

    kill('TERM', $_) for grep { kill(0, $_) } @$pids;

    for (1 .. 50) {
        @$pids = grep { (waitpid($_, POSIX::WNOHANG) != $_) && kill(0, $_) } @$pids;
        last unless @$pids;
        Time::HiRes::sleep(0.1);
    }

    for my $pid (@$pids) {
        kill('KILL', $pid) if kill(0, $pid);
        waitpid($pid, 0);
    }

    @{$self->{+AUX_PIDS}} = ();

    return;
}

# The preload root is wanted when this run actually preloads -- there
# are preload libraries configured AND we are not below the preload threshold
# (below threshold preloading is disabled and tests run via the clean fork+exec
# path). Mirrors the below_threshold computation the in-runner preloader()
# already does.
sub _preload_root_wanted {
    my $self = shift;

    my $preloads = $self->{+PRELOADS} // [];
    return 0 unless @$preloads;

    return 0 if $self->{+PRELOAD_THRESHOLD} && $self->{+JOBS_TODO} && $self->{+PRELOAD_THRESHOLD} > $self->{+JOBS_TODO};

    return 1;
}

# True once the preload-root process hosts ALL the preload stages
# (base/default included), so this runner is a pure orchestrator -- it schedules
# and dispatches over sockets and hosts NO stage in-process. LIVE for preload
# runs: spawn_preload_root sets PRELOAD_ROOT_HOSTS = 1, so this is true
# whenever preloads are configured and a preload-root was spawned.
# It stays false on the no-preload path (the runner forks each test job itself).
sub _preload_root_hosts_stages {
    my $self = shift;
    return $self->{+PRELOAD_ROOT_HOSTS} ? 1 : 0;
}

# True if at least one preload STAGE peer (any 'preload-<name>' except the
# preload-root handshake peer) is currently connected. The scheduler-only runner
# uses this as its base-stage-up signal: it does not dispatch a preload task until
# a stage has registered (its socket is the dispatch channel). The base stage's
# own name varies ('base' for a staged preload, 'default' for a non-staged one),
# so we never hardcode it.
sub _has_live_stage_peer {
    my $self = shift;

    my $peers = $self->{service_peers} or return 0;
    for my $id (sort keys %$peers) {
        next if $id eq 'preload-root';
        next unless $id =~ m/^preload-/;
        my $conn = $peers->{$id};
        next unless $conn && !$conn->closed;
        return 1;
    }

    return 0;
}

# The peer identity of the base/default stage -- the stage hosted IN the
# preload-root process (so its announced peer_pid equals PRELOAD_ROOT_PID). It is the
# only stage that owns the preload-root respawn jump frame and the only one whose
# channel the runner services for the whole run, so it is the reload target. Returns
# undef if no such peer is connected yet (no preload-root, or the base stage has not
# registered), in which case a reload is dropped rather than misrouted.
sub _preload_root_stage_identity {
    my $self = shift;

    my $root_pid = $self->{+PRELOAD_ROOT_PID} or return undef;
    my $peers    = $self->{service_peers}     or return undef;

    for my $id (sort keys %$peers) {
        next if $id eq 'preload-root';
        next unless $id =~ m/^preload-/;
        my $conn = $peers->{$id};
        next unless $conn && !$conn->closed;
        my $pid = $conn->peer_pid // next;
        return $id if $pid == $root_pid;
    }

    return undef;
}

# A connected preload stage's real pid comes from its 'preload-<stage>' peer
# connection (the pid it announced in the identity handshake -- ticket #1), not
# from the scheduler State (which stores no pid). Build a { stage => pid } map for
# status/ps from the live stage peers; a down/restarting stage has no live
# connection (or never announced a pid) and so gets no entry -- correctly absent.
sub stage_peer_pids {
    my $self = shift;

    my $peers = $self->{service_peers} or return {};

    my %pids;
    for my $id (sort keys %$peers) {
        next if $id eq 'preload-root';
        my ($stage) = $id =~ m/^preload-(.+)$/ or next;
        my $conn = $peers->{$id};
        next unless $conn && !$conn->closed;
        my $pid = $conn->peer_pid // next;
        $pids{$stage} = $pid;
    }

    return \%pids;
}

# The scheduler-only runner cannot dispatch a preload task until the stage map is
# reported AND at least one stage has registered (its socket is the dispatch
# channel). A command may submit its run + tasks before the preload-root finishes
# its handshake and the base stage registers; the runner buffers until both hold.
# Stage selection itself is resolved client-side from the task's preload directives
# against the map, so no round-trip to a stage is needed.
sub _ready_to_schedule {
    my $self = shift;

    return 1 unless $self->_preload_root_hosts_stages;
    return 0 unless $self->has_reported_stage_data;
    return 0 unless $self->_has_live_stage_peer;

    return 1;
}

# True if the preload-root process has exited (reaped here, since it is
# not in {+PROCS}). Used while waiting for stages to register so a preload-root that
# dies outright does not hang the run until the deadline.
sub _preload_root_dead {
    my $self = shift;

    # The per-tick subreaper sweep (_bring_out_yer_dead) may reap the preload-root
    # first (its waitpid(-1) cannot avoid it -- the root is the runner's child); it
    # flags PRELOAD_ROOT_REAPED so the death is still reported here rather than lost.
    return 1 if delete $self->{+PRELOAD_ROOT_REAPED};

    my $pid = $self->{+PRELOAD_ROOT_PID} or return 0;
    return 0 unless waitpid($pid, POSIX::WNOHANG()) == $pid;

    delete $self->{+PRELOAD_ROOT_PID};
    return 1;
}

# Preload-root death is fatal -- the runner does NOT respawn it (bloat #3,
# ARCHITECTURE.md §4.2). An unexpected exit terminates the runner (active runs
# fail). This is deliberate: it prevents accidentally recreating respawn-like
# behavior. HUP reload is the only restart path and the preload-root re-execs
# itself (same pid), so it is never seen as dead here. Returns:
#   ''        -- it is not dead, carry on
#   'fail'    -- it exited (a broken-preload stage_host_exited, or an abrupt crash);
#                SIGNAL is set so the caller winds the runner down.
sub _handle_dead_preload_root {
    my $self = shift;

    return '' unless $self->_preload_root_dead;

    # A broken preload's stage host *returns* and announces stage_host_exited (with
    # its captured errors); a crash (SIGKILL / an abrupt _exit) dies WITHOUT that
    # announcement. Either way the runner cannot host preloaded runs, so terminate.
    if ($self->stage_host_exited) {
        $self->_emit_preload_failure_output;
    }
    else {
        warn "$$ $0 preload-root died unexpectedly; terminating the runner\n";
        $self->_emit_preload_failure_output;
    }

    $self->{+SIGNAL} //= 'TERM';
    return 'fail';
}

# Surface the preload-root's (and its stages') captured STDERR when the preloads
# fail to come up, so the broken-preload diagnostic (a die in a preload, a stage
# that did not exit cleanly) reaches the command's output. The preload-root hands
# these over with stage_host_exited / preload_warnings; the runner just re-emits
# them. It does NOT decode the per-process events files itself -- each failed
# process's own collector already recorded its output, and the renderer surfaces it;
# the runner only needs to know there was a problem and fail the run. A hard crash
# (SIGKILL) hands nothing over, in which case the generic "died unexpectedly"
# message stands on its own.
sub _emit_preload_failure_output {
    my $self = shift;

    my $errors = $self->stage_host_errors;
    print STDERR $_ for @$errors;

    return;
}

# Apply a run/task submission, or buffer it until the scheduler is ready
# (see _ready_to_schedule). On every non-scheduler-only path there is no preload-root
# and this is a straight passthrough to State.
sub submit_action {
    my $self = shift;
    my ($method, @args) = @_;

    if ($self->_preload_root_hosts_stages && !$self->_ready_to_schedule) {
        push @{$self->{submit_buffer} //= []} => [$method, @args];
        return;
    }

    $self->state->$method(@args);

    return;
}

# Replay buffered submissions in order once the scheduler is ready.
sub flush_submit_buffer {
    my $self = shift;

    my $buf = delete $self->{submit_buffer} or return;
    for my $item (@$buf) {
        my ($method, @args) = @$item;
        $self->state->$method(@args);
    }

    return;
}

# Spawn the preload-root process (Test2::Harness2::Preload) -- the
# separate process that holds the preloaded interpreter state, so the runner does
# not. It is fork+exec'd under its own non-test collector (recording its
# stdout/stderr to preload-root-events.jsonl.zst, the same wire form as the runner
# and job collectors) and dials runner.socket to handshake (get_preload_list +
# set_stage_data).
#
# It is tracked like an aux process: NOT in {+PROCS}, so it never blocks
# the runner's wait(all=>1); stop_preload_root tears it down at wind-down, and its
# collector watches the runner pid (ARCHITECTURE.md §4.1) as the fallback. The
# preload-root deliberately never exits on its own mid-run, so the runner's
# waitpid(-1) reaper never trips over it.
sub spawn_preload_root {
    my $self = shift;

    return if $self->{+PRELOAD_ROOT_PID};

    require Test2::Collector;
    require Test2::Collector::Recorder::Zstd;

    my $socket = $self->service_socket_path;
    my @inc    = grep { !ref($_) && length($_) && $_ ne '.' } @INC;

    my @cmd = (
        $^X,
        (map { "-I$_" } @inc),
        "-MTest2::Harness2::Preload=launch,$socket",
        '-e' => '1;',
    );

    my $events = File::Spec->catfile($self->{+DIR}, 'preload-root-events.jsonl.zst');

    # The preload-root hosts the base/default stage IN-PROCESS, so its own
    # stdout/stderr (e.g. the base preload's "Loaded ..." lines, and any reload
    # output the base stage produces) is NOT a forked-stage collector's output and
    # would otherwise never reach `yath watch`. Give its collector a socket reporter
    # (like the per-stage and aux collectors) so its transitions stream to
    # runner.socket and the renderer surfaces them -- tagged INTERNAL like the
    # runner/stage streams, carrying the process's own `yath-nested-runner` $0.
    my $reporter = socket_reporter("collector:preload-root", $socket);

    my $pid = Test2::Collector::spawn_collector(
        is_test            => 0,
        name               => 'preload-root',
        exec               => \@cmd,
        record_transitions => 1,
        recorder           => Test2::Collector::Recorder::Zstd->new(file => $events),
        ($reporter ? (reporter => $reporter) : ()),
        watch_parent_pid => $self->{+ROOTPID},
    );

    $self->{+PRELOAD_ROOT_PID} = $pid;

    # The preload-root drives a stage-host Runner
    # (Preload::run_driver) that hosts EVERY stage (base/default/NOPRELOAD + named),
    # so this runner holds no preloaded state and hosts no stage in-process: its
    # run_scheduler_only loop dispatches every started task out over a stage's
    # registered channel. Stage resolution is client-side,
    # from each task's preload directives against the reported stage map (the
    # scheduler-only runner has no loaded preloader). Only the real root sets this
    # (spawn_preload_root is root-only via _preload_root_wanted).
    $self->{+PRELOAD_ROOT_HOSTS} = 1;

    return $pid;
}

# Tear the preload root down at runner wind-down. Ask it to stop over
# the channel it dialed (pumping the socket so the request is delivered and it is
# reaped), then TERM->KILL+reap by pid as the fallback -- the aux-process teardown
# shape (it is not in {+PROCS}).
sub stop_preload_root {
    my $self = shift;

    my $pid = $self->{+PRELOAD_ROOT_PID} or return;

    # Graceful: ask the preload-root to stop over the socket and reap it. The
    # preload-root may still be winding down its stage host when this arrives (it
    # only services this 'stop' once it reaches its idle loop), so give it a
    # generous window.
    eval { $self->service_send('preload-root', 'stop'); 1 };

    for (1 .. 250) {
        $self->service_io;
        last if waitpid($pid, POSIX::WNOHANG) == $pid;
        Time::HiRes::sleep(0.02);
    }

    # If it did not stop gracefully we must NOT kill the collector parent ($pid):
    # that collector's ChildMonitor (watch_parent_pid => this runner) is exactly
    # what kills the preload-root's exec'd child if the runner vanishes. Killing
    # the collector parent destroys that fallback and ORPHANS its child. Instead,
    # leave the collector parent alone and let the fallback fire: when this runner
    # process exits (right after teardown/stop below), the ChildMonitor sees the
    # runner gone, terminates the preload-root child (and its stage descendants),
    # and the collector parent finalizes and exits -- reaped by init. The
    # preload-root is tracked OUTSIDE {+PROCS} (so it never trips the
    # waitpid(-1) reaper), and it is still alive here, so a non-blocking reaper
    # sees no dead child to choke on.
    delete $self->{+PRELOAD_ROOT_PID};

    return;
}

# Stand up the always-on system-load sampler (ARCHITECTURE.md §4.4) as a global
# helper process under a collector, the same shape as the preload-root: a
# non-test collector whose ChildMonitor watches this runner (watch_parent_pid) so
# it self-terminates if the runner dies, recording to its own events file and
# reporting its transitions to runner.socket. The sampler itself dials runner.socket
# and pushes change-gated load snapshots. It runs in-process via a run sub (it does
# no fork+exec), so no separate Perl process is launched for it.
sub spawn_sampler {
    my $self = shift;

    return if $self->{+SAMPLER_PID};

    require Test2::Collector;
    require Test2::Collector::Recorder::Zstd;
    require Test2::Harness2::Service::Sampler;

    my $socket = $self->service_socket_path;
    my $events = File::Spec->catfile($self->{+DIR}, 'sampler-events.jsonl.zst');

    my $reporter = socket_reporter("collector:sampler", $socket);

    my $pid = Test2::Collector::spawn_collector(
        is_test            => 0,
        name               => 'sampler',
        record_transitions => 1,
        recorder           => Test2::Collector::Recorder::Zstd->new(file => $events),
        ($reporter ? (reporter => $reporter) : ()),
        watch_parent_pid => $self->{+ROOTPID},
        run              => sub {
            Test2::Harness2::Service::Sampler->new(
                workdir       => $self->{+DIR},
                name          => 'sampler',
                runner_socket => $socket,
            )->run;
        },
    );

    $self->{+SAMPLER_PID} = $pid;

    return $pid;
}

# Tear the sampler down at runner wind-down: ask it to stop over the channel it
# dialed (pumping the socket so the request is delivered and the sampler exits and
# its collector EOFs), then reap the collector parent by pid. Reaping it before the
# runner exits closes the std fds the sampler's collector inherited from this
# runner, so the runner's own collector is not held open past shutdown (the
# orphan-timeout stall, ARCHITECTURE.md §4.4). The sampler is tracked OUTSIDE
# {+PROCS} (like the preload-root and aux processes), so the non-blocking reaper
# never trips on it.
sub stop_sampler {
    my $self = shift;

    my $pid = $self->{+SAMPLER_PID} or return;

    eval { $self->service_send('sampler', 'stop'); 1 };

    for (1 .. 250) {
        $self->service_io;
        last if waitpid($pid, POSIX::WNOHANG) == $pid;
        Time::HiRes::sleep(0.02);
    }

    # If it did not stop gracefully, the sampler's collector parent (this $pid) is
    # still alive holding the inherited std fds. Signal the collector parent so it
    # tears its child down and finalizes; then block-reap it so those fds are
    # closed before this runner exits.
    if (kill(0, $pid)) {
        kill('TERM', $pid);
        for (1 .. 100) {
            $self->service_io;
            last if waitpid($pid, POSIX::WNOHANG) == $pid;
            Time::HiRes::sleep(0.02);
        }
        if (kill(0, $pid)) {
            kill('KILL', $pid);
            waitpid($pid, 0);
        }
    }

    delete $self->{+SAMPLER_PID};

    return;
}

# On the transient path the runner is the completion/stalled/timeout authority
# (there is no yath-side gatherer). The watchdog folds the stalled-job detection
# and abort-on-wind-down duties into the scheduler tick over canonical state. The
# standing gatherer survives only for the gated persistent path.
sub watchdog {
    my $self = shift;
    return $self->{+WATCHDOG} //= Test2::Harness2::Runner::Watchdog->new(runner => $self);
}

# Hand started tasks bound for socketed stages out to those stages.
sub dispatch_pending {
    my $self = shift;

    my $state = $self->state;

    # Take EVERY started task off the list (slot + resources already accounted by
    # _start_task, so they stay tracked as RUNNING). A preload run sends each out to
    # its stage's registered channel; a no-preload run forks each test's collector in
    # this runner (there is no stage to dispatch to).
    my @tasks = $state->take_dispatch_tasks(undef) or return;

    # Preload run: dispatch down the registered channel each stage opened to us
    # (service_send by peer identity).
    if ($self->_preload_root_hosts_stages) {
        my $run_item = $state->run_item;

        for my $task (@tasks) {
            my $stage = $task->{stage};

            # One-way per-test dispatch: run_task's handler returns undef (no
            # reply), so skip the PENDING insert -- otherwise a request_id would
            # leak per test on a daemon-lifetime channel. (#134 finding 106)
            my $sent = $self->service_send("preload-$stage", 'run_task', task => $task, run => $run_item, want_reply => 0);

            # service_send returns false when the stage's channel is gone (no peer, or
            # the write failed because the peer vanished mid-write) -- the stage NEVER
            # received the task, so it never forked the job and never took ownership of
            # its completion. This is the assign->launch race (§4.7a) / a self-restarting
            # stage taking its channel: the job is owed a run, not a failure. REQUEUE it
            # (bloat #3) -- release its slot / resources and put it back PENDING (no retry
            # consumed) to be re-resolved on a later tick. Requeuing is safe ONLY because
            # no stage accepted it; once a stage forks the job its collector owns
            # completion and requeuing would duplicate-run.
            unless ($sent) {
                $self->requeue_task($task);
                next;
            }

            # Dispatching a job to a stage is a runner-originated state mutation;
            # forward it to subscribers so their mirror sees the job move.
            $self->announce_job($task->{job_id}, 'dispatched', stage => $stage, file => $task->{file}, run_id => $task->{run_id});
        }

        return;
    }

    # No-preload run: this runner IS the 'default' stage; fork each test's collector
    # locally (a clean-slate fork+exec -- no preloaded interpreter, no goto::file).
    my $run = $state->run() or return;
    for my $task (@tasks) {
        $self->_launch_local_job($task, $run);
    }

    return;
}

# The runner's ONE run loop (#29). It services runner.socket (stage registrations +
# transitions + client requests) and ticks the in-process scheduler, which dispatches
# every started task (see dispatch_pending). On a PRELOAD run the preload-root hosts
# the stages and each task is dispatched out to its stage's registered channel; on a
# NO-PRELOAD run there is no preload-root and the runner forks each test's collector
# itself from its in-process 'default' stage (set up below). It ends on a shutdown
# signal or run completion.
sub run_scheduler_only {
    my $self = shift;

    # Wait until the preload-root has reported the stage map AND at least one
    # stage is connected (the dispatch channel), so buffered run/task submissions
    # can be bucketed and dispatched correctly. Submissions that arrive during this
    # window are buffered by submit_action; flush them once ready. If the preload-root
    # never becomes ready, wind down rather than hang. The deadline is configurable
    # (--preload-map-timeout) because some preloads legitimately take a long time to
    # load before the base stage can report the map.
    my $deadline = time + ($self->settings->runner->preload_map_timeout // 60);
    until ($self->_ready_to_schedule) {
        $self->service_io;

        # A broken preload's stage host *returns* and announces stage_host_exited
        # (with its captured errors): a real failure, fail fast.
        if ($self->stage_host_exited) {
            $self->_emit_preload_failure_output;
            $self->{+SIGNAL} //= 'TERM';
            last;
        }

        # The preload-root dying (a crash without that announcement, or a broken
        # preload) is fatal -- the runner does NOT respawn it (bloat #3); terminate.
        last if $self->_handle_dead_preload_root;

        if (time > $deadline) {
            warn "$$ $0 preload-root never became ready (no stage map / stage); aborting run\n";
            $self->_emit_preload_failure_output;
            $self->{+SIGNAL} //= 'TERM';
            last;
        }
        Time::HiRes::sleep(0.01);
    }

    $self->flush_submit_buffer;

    # No-preload run: there is no preload-root, so the runner's own in-process
    # 'default' stage stands in. preload() builds the dtrace the reload/monitor HUP
    # check and --dump-depmap need (it preloads nothing when no preloads are
    # configured; the tests fork+exec fresh, so they need no preheated interpreter).
    # Then mark 'default' ready -- the scheduler only dispatches tasks bucketed under
    # an 'up' stage, and every no-preload task resolves to 'default'. The preload path
    # gets its stages 'up' from each stage's registration instead.
    unless ($self->_preload_root_hosts_stages) {
        my $preloader = $self->preloader;
        $preloader->preload();

        if ($self->dump_depmap) {
            if (my $dtrace = $preloader->dtrace) {
                if (my $depmap = $dtrace->dep_map) {
                    write_file("depmap-default.json", encode_json($depmap));
                }
            }
        }

        $self->{+STAGE} //= 'default';
        $self->state->stage_ready($self->{+STAGE});
    }

    while (1) {
        $self->service_io;
        $self->service_tick;

        # Reap re-parented detached preload collectors each tick (ticket #28 C1: the
        # runner is their child subreaper, so nobody else reaps them). Pure zombie
        # cleanup + the A3 post-pass health escalation -- the completion decision
        # always rides EOF. Must run BEFORE the dead-preload-root check below: this
        # sweep's waitpid(-1) may reap the preload-root, and it flags
        # PRELOAD_ROOT_REAPED so _handle_dead_preload_root still detects the death.
        $self->_bring_out_yer_dead;
        $self->_check_if_dead_yet;

        last if $self->{+SIGNAL};
        last if $self->state->done;

        # A stage host that exits WITH errors mid-run (a stage that died after coming
        # up -- e.g. a preload that fails inside a stage) cannot finish the run; surface
        # its diagnostic and wind down rather than spinning. A clean stage-host exit (no
        # errors) only happens after we have told the stages to stop at wind-down, so it
        # never lands here.
        if ($self->stage_host_exited && @{$self->stage_host_errors}) {
            $self->_emit_preload_failure_output;
            $self->{+SIGNAL} //= 'TERM';
            last;
        }

        # The preload-root dying mid-run (a crash without a clean stage_host_exited)
        # is fatal: the runner cannot host preloaded runs and does NOT respawn it
        # (bloat #3, ARCHITECTURE.md §4.2). It sets SIGNAL so the runner winds down;
        # active runs fail. In-flight test jobs detect their vanished ancestors via
        # their own collectors (watch_parent_pid) independently.
        last if $self->_handle_dead_preload_root;

        # No-preload run: the in-runner shutdown triggers ported from the retired
        # end_test_loop -- a persistent runner whose workdir/pfile vanished self-shuts
        # down (orphaned), and a reload request winds down for a HUP respawn. The
        # preload path winds down on stage-host signals instead, so this is
        # no-preload-scoped. (Goes live when the no-preload run is routed here -- #29.)
        unless ($self->_preload_root_hosts_stages) {
            if ($self->orphaned) {
                $self->{+SIGNAL} //= 'TERM';
                last;
            }

            no warnings 'uninitialized';
            if ($self->preloader->check($self->state)) {
                $self->{+SIGNAL} //= 'HUP';
                last;
            }
        }

        Time::HiRes::sleep($self->{+WAIT_TIME}) if $self->{+WAIT_TIME};
    }

    # Synthesize an abort for any task still tracked as running whose stage never
    # reported completion, so the command-side driver rolls it up as failed rather
    # than "never ran" (the same wind-down duty the staged loop performs).
    $self->watchdog->abort_remaining unless $self->{+PERSIST};

    # The stages are children of the preload-root, not this runner, so
    # they are not in {+PROCS}; we only know them as registered `preload-<name>`
    # peers. The run is done, so tell every stage to stop over the channel it opened
    # to us. Once all stages stop, the preload-root's own stage-host run loop ends
    # and that process exits -- stop_preload_root then reaps it.
    $self->stop_preload_stages;

    # No-preload run: the test collectors are THIS runner's own forked children, so
    # signal them on a wind-down and block until they are reaped (ported from the
    # retired in-runner run_stage wind-down). The preload path's stages are the
    # preload-root's children, stopped above. (Goes live when no-preload routes here.)
    unless ($self->_preload_root_hosts_stages) {
        $self->killall($self->{+SIGNAL}) if $self->{+SIGNAL};
        $self->wait(all => 1);
    }

    # Final best-effort reap of any detached collector that has already exited by
    # wind-down (ticket #28 C1); ones still finishing re-parent to init on exit (an
    # accepted loss -- the run is over and every verdict already rode EOF).
    $self->_bring_out_yer_dead;
    $self->_check_if_dead_yet;

    return;
}

# Send a graceful 'stop' to every connected preload stage peer
# (identities `preload-<name>`, excluding the preload-root's own handshake peer).
# On the preload path the stages are the preload-root's children (hosted by
# Test2::Harness2::Preload::Host), not this runner's, so the runner only knows them
# as registered `preload-<name>` peers and stops them over those channels.
sub stop_preload_stages {
    my $self = shift;

    my $peers = $self->{service_peers} or return;
    for my $identity (keys %$peers) {
        next unless $identity =~ m/^preload-/;
        next if $identity eq 'preload-root';
        eval { $self->service_send($identity, 'stop'); 1 };
    }

    return;
}

# Launch ONE test job locally: the runner forks its own collector for the test (the
# no-preload path -- there is no preload stage to dispatch to, so the runner is the
# 'default' stage). The single local-launch implementation, called by dispatch_pending
# for every task on a no-preload run. Returns the forked job's pid. (`yath spawn`
# never reaches the runner at all -- it connects directly to a preload stage's
# socket, ARCHITECTURE.md §4.8.)
sub _launch_local_job {
    my $self = shift;
    my ($task, $run) = @_;

    my $job_class;
    if ($task->{job_class}) {
        $job_class = $task->{job_class};
        require(mod2file($job_class));

        die "Custom job class $job_class overrode the category, this is a fatal mistake"
            unless $job_class->category eq $self->job_class->category;
    }
    else {
        $job_class = $self->job_class;
    }

    my $job = $job_class->new(
        runner        => $self,
        task          => $task,
        run           => $run,
        settings      => $self->settings,
        fork_callback => $self->{+FORK_JOB_CALLBACK},
    );

    $job->prepare_dir();

    my $pid;
    my $via = $job->via();
    if ($via) {
        require(mod2file($1)) if !defined(&{$via}) && $via =~ m/^(.+)::[^:]+$/;

        $pid = $self->$via($job);
        $job->set_pid($pid);
        $self->watch($job);
    }
    else {
        $self->spawn($job);
        $pid = $job->pid;
    }

    # Forking a test job is a runner-originated state mutation; forward
    # it to subscribers so their mirror sees the job go running.
    $self->announce_job($task->{job_id}, 'running', stage => $task->{stage}, file => $task->{file}, run_id => $task->{run_id});

    # Track the job's pid for the status/ps/abort report. The runner
    # records it directly (it is the job-pid authority). (A preload-stage's
    # forked jobs are reported to the runner via the job_pid request from
    # Test2::Harness2::Preload::Host.)
    $self->record_job_pid($task->{job_id}, $pid);

    return $pid;
}

sub orphaned {
    my $self = shift;

    # A persistent runner whose workdir or persistence file has been removed has
    # lost its owner (a `yath stop`, or a starter that died and got cleaned up).
    # Nothing will ever drive it again, so shut down instead of idling forever
    # and respawning preload stages. Already-signalled shutdowns are left alone.
    return 0 if $self->{+SIGNAL};

    my $dir = $self->{+DIR};
    return 1 if $dir && !-d $dir;

    my $pfile = $self->{+PERSIST};
    return 1 if $pfile && !-e $pfile;

    return 0;
}

sub set_proc_exit {
    my $self = shift;
    my ($proc, $exit, $time, @args) = @_;

    if ($proc->isa('Test2::Harness2::Runner::Job')) {
        # Reaping a test-job collector is now pure zombie cleanup. The runner
        # decides the test's outcome (retry / stop / bail) from the collector's
        # transitions + connection EOF on runner.socket (ARCHITECTURE.md §5.4), NOT
        # from this reaped exit code: the exit code cannot express a bail-out, and
        # on the preload path the runner never sees it. The EOF handler
        # (collector_conn_eof) already cleared job_pids and decided; here we only
        # clear the timeout marker. job_pids is deleted defensively in case the reap
        # races ahead of the EOF (the EOF decision is still fire-once guarded).
        my $task   = $proc->task;
        my $job_id = $task->{job_id};
        delete $self->{+JOB_PIDS}->{$job_id};
        delete $self->{+RUN_REACHED_TIMEOUT}->{$job_id}
            if ref $self->{+RUN_REACHED_TIMEOUT};

        # Post-pass collector failure (A3, ARCHITECTURE.md §5.4): this no-preload
        # collector is the runner's own child, so the runner DOES see its health
        # exit here. The exit is HEALTH-ONLY now (the verdict rode the transitions),
        # so a NON-ZERO exit means the collector itself malfunctioned.
        $self->_check_post_pass_health($job_id, $exit);
    }

    # A preload stage exiting (reload/monitor relaunch, or death) is handled by the
    # stage host (Test2::Harness2::Preload::Host), not the runner: the runner forks
    # no preload stages (ticket #22). The runner only reaps its own test jobs and
    # the no-preload path's nothing-else.

    $self->SUPER::set_proc_exit($proc, $exit, $time, @args);
}

# Post-pass collector-failure escalation (A3, ARCHITECTURE.md §5.4). If $job_id
# already reported a pass and its collector then exited NON-ZERO (a health-only
# exit, so non-zero means the collector itself malfunctioned), keep the test green
# but flag the suite failed -- the only place the collector exit code is ever
# consulted, and only post-hoc + suite-level. Shared by both reaping paths: the
# no-preload runner-owned child (set_proc_exit) and the re-parented preload
# collector reaped as an unwatched zombie (_bring_out_yer_dead). On an unsupported
# platform the runner never reaps the detached collector, so a preload post-pass
# failure may be lost -- accepted per §5.4.
sub _check_post_pass_health {
    my $self = shift;
    my ($job_id, $exit) = @_;

    return unless defined $job_id;

    my $passed_run = delete $self->{'job_passed'}{$job_id};
    return unless defined $passed_run;
    return unless $exit;
    return unless $self->can('announce_run_health');

    $self->announce_run_health(
        $passed_run eq '' ? undef : $passed_run,
        "A test collector for a PASSING job exited non-zero (health exit) after reporting its result; the test stays passed but the collector malfunctioned (job $job_id)",
    );

    return;
}

# The runner is a child subreaper (ticket #28), so it reaps every re-parented
# detached preload test collector here even though it never watched them. The base
# reaper discards an unwatched pid; the runner additionally maps it back to its job
# (via the pid-keyed collector_reap map, #28 C2) and runs the A3 post-pass health
# escalation so a detached collector that failed AFTER reporting a pass still flags
# the suite (ARCHITECTURE.md §5.4). Watched pids (no-preload children) go to WAITING
# for set_proc_exit as before; the decision itself always rides EOF, so this reap is
# pure zombie cleanup + the A3 escalation.
sub _bring_out_yer_dead {
    my $self = shift;

    my $procs   = $self->{+PROCS}   //= {};
    my $waiting = $self->{+WAITING} //= {};

    local $?;

    my $found = 0;
    while ((my $pid = waitpid(-1, POSIX::WNOHANG)) > 0) {
        my $exit = $?;

        # The preload-root is tracked separately (not in PROCS); if this unconditional
        # sweep reaps it before _preload_root_dead's targeted waitpid, flag the death
        # so _handle_dead_preload_root still fires rather than missing it forever.
        if ($self->{+PRELOAD_ROOT_PID} && $pid == $self->{+PRELOAD_ROOT_PID}) {
            delete $self->{+PRELOAD_ROOT_PID};
            $self->{+PRELOAD_ROOT_REAPED} = 1;
            next;
        }

        if ($procs->{$pid}) {
            $found++;
            $waiting->{$pid} = [$exit, time()];
            next;
        }

        # Unwatched pid: a re-parented detached preload collector (or a benign
        # plugin/3rd-party child). If it maps to a passed job, apply the A3 escalation.
        $self->_reaped_unwatched_pid($pid, $exit);
    }

    return $found;
}

# A pid reaped here that the runner never watched: a re-parented detached preload
# collector, or a benign child a plugin/3rd-party module forked. Map it back to its
# job via the pid-keyed collector_reap entry (recorded when the job reported a pass,
# and kept alive past the collector's EOF specifically for this lookup -- job_pids,
# the status map, is cleared at that EOF and cannot serve here) and run the A3
# post-pass health check. A pid with no entry -- a non-pass job, or a foreign child
# -- is simply ignored. Pid-keyed, so each collector incarnation is matched exactly
# (try-safe) with no reverse scan.
sub _reaped_unwatched_pid {
    my $self = shift;
    my ($pid, $exit) = @_;

    my $map = $self->{'collector_reap'} or return;
    my $rec = delete $map->{$pid} or return;

    $self->_check_post_pass_health($rec->{job_id}, $exit);

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner - Base class for test runners

=head1 DESCRIPTION

This module does the heavy lifting of running all the tests.

You should never need to create an instance of the runner yourself. In most
cases the runner module is exposed via a callback or a plugin affordance.

=head1 PUBLIC METHODS

=head2 FROM SETTINGS

These are attributesd with values set from the L<Getopt::Yath::Settings>
instance created from command line arguments.

See L<App::Yath2::Options::Runner> for the most up to date documentation on
these.

=over 4

=item $runner->includes

=item $runner->tlib

=item $runner->lib

=item $runner->blib

=item $runner->unsafe_inc

=item $runner->use_fork

=item $runner->preloads

=item $runner->preload_threshold

=item $runner->switches

=item $runner->cover

=item $runner->event_timeout

=item $runner->post_exit_timeout

=back

=head2 FROM CONSTRUCTION

These attributes are set when the runner is created.

=over 4

=item $path = $runner->dir

Path to the working directory.

=item $settings = $runner->settings

The L<Getopt::Yath::Settings> instance.

=item $coderef = $runner->fork_job_callback

Callback used to spawn new tests via fork.

=item $bool = $runner->monitor_preloads

True if preloads should be watched for changes.

=item $int = $runner->jobs_todo

A count of total jobs to run. This will always be 0 in a persistent runner.

=back

=head2 OTHER PUBLIC METHODS

If a method is not documented here then it is an implementation detail and you
should not use it.

=over 4

=item $class = $runner->job_class

Class for new test jobs.

=item $preload = $runner->preloader

Get the L<Test2::Harness2::Runner::Preloader> instance.

=item $state = $runner->state

Get the L<Test2::Harness2::Runner::State> instance.

=item $monitor = $runner->monitor

Get the L<Test2::Harness2::Runner::Monitor> instance: the runner-side fold of
the collector transition channel. Non-runner collectors stream their transitions
to C<runner.socket> and the runner folds them into this canonical in-process
state.

=item @list = $runner->all_libs

Get all the libs that should be added to @INC by default. Note that specific
runs and even specific tests can have custom paths on top of these.

=item $bool = $runner->become_subreaper

Mark the runner as a child subreaper so it owns reaping for the whole process
tree (detached preload collectors re-parent to it). Returns true on success,
false on an unsupported platform or a failed acquire (both non-fatal). All
platform/syscall logic lives in L<Test2::Harness2::Util::SubReaper>.

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
