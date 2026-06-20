package Test2::Harness2::Runner;
use strict;
use warnings;

our $VERSION = '2.000000';

use File::Spec();

use Carp qw/confess croak/;
use POSIX qw/:sys_wait_h/;
use Long::Jump qw/setjump longjump/;
use Time::HiRes qw/sleep time/;

use Test2::Harness2::Util qw/clean_path file2mod mod2file parse_exit write_file_atomic process_includes chmod_tmp write_file collector_exit_code runner_events_file socket_reporter/;
use Test2::Harness2::Util::Queue();
use Test2::Harness2::Util::JSON(qw/encode_json/);

use Test2::Harness2::Runner::Constants;

use Test2::Harness2::Runner::Run();
use Test2::Harness2::Runner::Job();
use Test2::Harness2::Runner::Spawn();
use Test2::Harness2::Runner::State();
use Test2::Harness2::Runner::Preload();
use Test2::Harness2::Runner::Preloader();
use Test2::Harness2::Runner::Preloader::Stage();
use Test2::Harness2::Runner::DepTracer();
use Test2::Harness2::Runner::Stage();
use Test2::Harness2::Runner::Monitor();
use Test2::Harness2::Runner::Watchdog();
use Test2::Harness2::Runner::StatusReport();

use Test2::Harness2::Runner::Role::Service::Handlers();
use Test2::Harness2::Runner::Role::Scheduler();

use Test2::Harness2::Plugin();    # chunk 17: $AUX_PIDS registry + run_collected/shellcall

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
        <dir <settings <fork_job_callback <fork_spawn_callback <respawn_runner_callback <monitor_preloads
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
        +can_stage
        <tmp_dir

        <rootpid

        +stage_delegate

        +monitor
        +watchdog

        +announced_runs
        +active_run

        +job_pids

        +plugins
        +aux_pids

        +preload_root_pid
        +reported_stage_data
        +preload_root_hosts
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

# Chunk 6 (phase D): launch the runner process under its own non-test collector
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

# A preload stage is itself a service (chunk 5d/6.1-2): the forked stage child
# rebinds the service socket to 'preload-<stage>.socket' in the workdir and the
# runner connects out to it to dispatch jobs. The root process keeps the 'runner'
# name / runner.socket. This applies to BOTH the transient and persistent paths:
# a persistent forked stage is a dispatch service too (chunk 6.1-2), so it no
# longer polls dispatch.jsonl for work.
sub service_name {
    my $self = shift;
    return 'runner' if $self->{+ROOTPID} == $$;
    my $stage = $self->{+STAGE} // return 'runner';
    return "preload-$stage";
}

# Chunk 6.1-2 SEAM (run-scoped preload stages -- NOT YET TRIGGERED):
# Test2::Harness2::Role::Service nests a service's socket under runs/<run_id>/
# when the consumer provides run_id, so a per-run preload stage would bind
# runs/<run_id>/preload-<stage>.socket and two runs on one persistent runner
# could not collide. The runner deliberately does NOT define run_id: execution
# is serialized (one active run) and preload stages are GLOBAL (shared,
# runner-lifetime, flat preload-<stage>.socket), so there is no per-run stage to
# scope or tear down. Implementing run_id (+ a run-end stage teardown, +
# run-scoped peer identities) is the seam for the future run-scoped-stage
# feature; it is intentionally left unbuilt here (no trigger exists).

# True when this process is a forked preload stage acting as a socket-dispatch
# service (not the root runner). Applies to the transient AND persistent paths
# (chunk 6.1-2): every forked stage receives dispatched work over its own socket
# instead of polling dispatch.jsonl.
sub is_stage_service {
    my $self = shift;
    return 0 if $self->{+ROOTPID} == $$;
    return $self->{+STAGE} ? 1 : 0;
}

our $RUNNER_PID;

sub init {
    my $self = shift;

    # Chunk 19.2a: honor an injected rootpid (the logical root runner's pid),
    # defaulting to this process when none is given. A process whose $$ differs
    # from rootpid (the preload-root driving a stage-host Runner, later substeps)
    # then identifies as a stage rather than the root via is_stage_service /
    # service_name / scheduler_tick. $RUNNER_PID tracks the logical root so
    # resource accounting keys on the real runner, not a child.
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

        # When the preload-root hosts the stages this runner is scheduler-only and
        # holds NO preloaded interpreter state, so it must NOT wind down on HUP --
        # reload lives entirely in the preload tree. Forward the reload to the
        # preload-root and keep scheduling. The preload-root re-execs itself from a
        # clean interpreter (Test2::Harness2::Preload::request_handler_reload); it
        # also shares this runner's process group, so a HUP delivered to the group
        # reaches it directly as well.
        if ($self->{+ROOTPID} == $$ && $self->{+PRELOAD_ROOT_PID}) {
            $self->service_send('preload-root', 'reload');
            return;
        }

        # Legacy in-runner reload path: the real no-preload runner (self-restart via
        # the command's setjump "Test-Runner" frame) and a stage-host base/default
        # runner (rootpid != $$, respawn via longjump 'preload-root') both reload by
        # setting SIGNAL=HUP, which their stage's end_test_loop turns into a respawn.
        print "$$ $0 ($self->{+STAGE}) Runner caught SIG$sig, reloading...\n";
        $self->{+SIGNAL} = $sig;
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
        runner_pid      => $self->{+ROOTPID},

        below_threshold => ($self->{+PRELOAD_THRESHOLD} && $self->{+JOBS_TODO} && $self->{+PRELOAD_THRESHOLD} > $self->{+JOBS_TODO}) ? 1 : 0,
    );
}

sub state {
    my $self = shift;

    # A transient forked preload stage no longer polls dispatch.jsonl for work
    # (chunk 5d): it receives dispatched tasks over its own socket and reports
    # outcomes back to runner.socket. It uses a lightweight in-stage delegate that
    # exposes the same next_task/run/stop_task/retry_task API run_job/set_proc_exit
    # call, so the shared run loop is unchanged.
    return $self->stage_delegate if $self->is_stage_service;

    my $settings = $self->settings;

    # Chunk 19.3: when the preload-root hosts the stages this runner is
    # scheduler-only and holds NO preloader. State resolves a task's stage from the
    # reported stage map (eager fan-out rebuilt from the map's can_run) and, for
    # file_stage / default resolution, a resolve_file_stages round-trip to the base
    # stage (the only process with the loaded preload meta). set_stage_data refreshes
    # eager_stages / stage_map on the built State when the map arrives.
    if ($self->_preload_root_hosts_stages) {
        $self->{+STATE} //= Test2::Harness2::Runner::State->new(
            workdir             => $self->{+DIR},
            eager_stages        => $self->eager_from_stage_map,
            stage_map           => $self->reported_stage_data // {},
            file_stage_resolver => sub { $self->resolve_file_stage($_[0]) },
            resources           => [map { $_->new(settings => $settings) } @{$self->{+RESOURCES}}],
            settings            => $settings,
        );
        return $self->{+STATE};
    }

    my $preloader = $self->preloader;

    $self->{+STATE} //= Test2::Harness2::Runner::State->new(
        workdir      => $self->{+DIR},
        eager_stages => $preloader->eager_stages // {},
        preloader    => $preloader,
        resources    => [map { $_->new(settings => $settings) } @{$self->{+RESOURCES}}],
        settings     => $settings,
    );

    # The runner is the sole writer/reader of its scheduling state: stages receive
    # work over sockets (chunk 5d transient, chunk 6.1-2 persistent) and the
    # run/spawn/abort/status/resources commands submit + query over runner.socket.
    # The State applies every action in-process; dispatch.jsonl (A2) is gone -- it
    # has no remaining writer or reader on either path.
    return $self->{+STATE};
}

# The lightweight in-stage delegate a transient forked preload stage uses in
# place of State (chunk 5d). Built once per stage child; it holds the dispatched
# task queue and reports outcomes back to the runner via service_send over the
# single registered service channel (the connection the stage opened to send
# stage_ready), not a second connect-out to runner.socket.
sub stage_delegate {
    my $self = shift;
    return $self->{+STAGE_DELEGATE} //= Test2::Harness2::Runner::Stage->new(
        workdir => $self->{+DIR},
        name    => $self->{+STAGE},
        runner  => $self,
    );
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
    # What remains here is a backstop for a collector PARENT that should have
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

sub process {
    my $self = shift;

    @INC = process_includes(
        list            => [@{$self->settings->harness->dev_libs}, $self->all_libs],
        include_dot     => $self->unsafe_inc,
        include_current => 1,
        clean           => 1,
    );

    # Root-only: the workdir PID file names the real runner. A stage-host Runner
    # (the preload-root, rootpid != $$) must not clobber it.
    if ($self->{+ROOTPID} == $$) {
        my $pidfile = File::Spec->catfile($self->{+DIR}, 'PID');
        write_file_atomic($pidfile, "$$");
    }

    # Propagate the workdir to every child (collectors, stages, jobs) so they can
    # locate runner.socket without hardcoded assumptions (ARCH 5.3). Setting it in
    # the runner process means forked stages inherit it directly, and the
    # Test2::Collector child_env merge carries it on into test children; jobs also
    # set it explicitly in their curated env (Runner::Job::env_vars).
    $ENV{T2_HARNESS_WORKDIR} = $self->{+DIR};

    # Bind runner.socket and run the accept/request loop coexisting with the
    # run loop (chunk 5a scaffolding). The scheduler is now an in-runner object
    # ticked each service-loop iteration (chunk 5b). The transient `yath test`
    # command submits its run and tasks over this socket (chunk 5c), which the
    # request handlers fold into the in-process State. As of chunk 5g the
    # transient path no longer writes queue.jsonl/jobs.jsonl (the gatherer that
    # read them is retired there); they remain only for the gated persistent path.
    #
    # Root-only: this binds runner.socket. A stage-host Runner (the preload-root,
    # rootpid != $$) must NOT bind runner.socket (it would collide with the real
    # runner); its stages bind their own preload-<stage>.socket in run_stage and
    # dial the real runner.socket from there.
    $self->start_service if $self->{+ROOTPID} == $$;

    # Chunk 17: plugin setup() runs HERE, in the runner, after runner.socket is
    # bound -- so a plugin's aux work (shellcall / run_collected) reports to the
    # socket as collector events instead of flat aux_logs files, and any aux
    # process is a runner child that dies with the runner. teardown() runs below,
    # after the run loop, before stop().
    $self->setup_plugins;

    # Chunk 19.1: stand up the separate preload-root process (it dials this socket
    # and handshakes). Spawned-but-idle alongside the existing in-runner preload
    # path for now; later substeps move stage forking + test launching into it and
    # retire the in-runner path.
    $self->spawn_preload_root if $self->_preload_root_wanted;

    $self->start();

    my $ok  = eval { $self->run_tests(); 1 };
    my $err = $@;
    $self->{+CAN_STAGE} = 0;

    warn $err unless $ok;

    # Chunk 19.1: tear the preload-root down before plugin teardown/stop so it is
    # reaped while the runner is still servicing its socket.
    $self->stop_preload_root;

    $self->teardown_plugins;

    $self->stop();

    # Chunk 5g: the transient command's render completion is the runner closing
    # this socket. Before we close, drain any in-flight transition frames a job
    # collector flushed late (e.g. a stage's last job, whose final_state can race
    # the stage's stop_task report) so they are folded and forwarded to the
    # subscriber. By now stop() has reaped every child (the stages, and through
    # them their job collectors), so a few non-blocking service passes capture the
    # remainder. Root / transient only; the gated persistent path has the gatherer.
    $self->_drain_transitions if $self->{+ROOTPID} == $$ && !$self->{+PERSIST};

    # Root-only: the real runner closes runner.socket here (its close is the
    # transient command's completion signal). A stage-host Runner's services
    # (its stages' preload-<stage>.socket) are closed by run_stage as each stage
    # ends; it never bound runner.socket, so there is nothing to close here.
    $self->close_service if $self->{+ROOTPID} == $$;

    return $self->{+SIGNAL} ? 128 + $self->SIG_MAP->{$self->{+SIGNAL}} : $ok ? 0 : 1;
}

# Chunk 5g: final non-blocking sweep of the service socket so transitions that
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
    my $deadline = Time::HiRes::time() + 0.5;
    while (1) {
        $self->service_io;

        last if Time::HiRes::time() >= $deadline;

        my $sel = $self->{service_select} or last;
        last unless $sel->can_read(0);

        Time::HiRes::sleep(0.01);
    }

    return;
}

# Chunk 17: plugin setup/teardown run in the runner (not the command). The command
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
    my $specs = $harness->check_option('plugin_specs') ? $harness->plugin_specs : undef;
    $specs //= [];

    my (%seen, @plugins);
    for my $spec (@$specs) {
        my ($class, $args) = split /=/, $spec, 2;
        next if $seen{$class}++;
        my @args = defined($args) ? (split /,/, $args) : ();

        my $file = mod2file($class);
        my $ok = eval { require $file unless $INC{$file}; 1 };
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
    return unless $self->{+ROOTPID} == $$;

    $self->{+AUX_PIDS} //= [];
    local $Test2::Harness2::Plugin::AUX_PIDS = $self->{+AUX_PIDS};
    $_->setup($self->settings) for @{$self->plugins};

    return;
}

sub teardown_plugins {
    my $self = shift;
    return unless $self->{+ROOTPID} == $$;

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
# the runner pid (ARCHITECTURE.md §4.1) as the backstop if the runner dies hard.
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

# Chunk 19.1: the preload root is wanted when this run actually preloads -- there
# are preload libraries configured AND we are not below the preload threshold
# (below threshold preloading is disabled and tests run via the clean fork+exec
# path). Mirrors the below_threshold computation the in-runner preloader()
# already does.
sub _preload_root_wanted {
    my $self = shift;

    return 0 unless $self->{+ROOTPID} == $$;

    my $preloads = $self->{+PRELOADS} // [];
    return 0 unless @$preloads;

    return 0 if $self->{+PRELOAD_THRESHOLD} && $self->{+JOBS_TODO} && $self->{+PRELOAD_THRESHOLD} > $self->{+JOBS_TODO};

    return 1;
}

# True once the preload-root process hosts ALL the preload stages
# (base/default included), so this runner is a pure orchestrator -- it schedules
# and dispatches over sockets and hosts NO stage in-process. LIVE for preload
# runs: spawn_preload_root sets PRELOAD_ROOT_HOSTS = 1 (the chunk-19.3 flip), so
# this is true whenever preloads are configured and a preload-root was spawned.
# It stays false on the no-preload path (the runner forks each test job itself).
sub _preload_root_hosts_stages {
    my $self = shift;
    return 0 unless $self->{+ROOTPID} == $$;
    return $self->{+PRELOAD_ROOT_HOSTS} ? 1 : 0;
}

# Chunk 19.3: rebuild the eager-stage fan-out from the stage data the preload-root
# reported. The reported map is { <stage> => { can_run => [...], default => 0|1 } };
# State::_stage_order wants { <stage> => [<eager children>] } for stages whose
# can_run is non-empty (an eager stage runs its nested stages' tests when it would
# otherwise idle). The scheduler-only runner has no preloader to ask, so it derives
# this from the reported map instead of preloader->eager_stages.
sub eager_from_stage_map {
    my $self = shift;

    my $map = $self->reported_stage_data or return {};

    my %eager;
    for my $name (keys %$map) {
        my $can = $map->{$name}->{can_run} or next;
        next unless @$can;
        $eager{$name} = [@$can];
    }

    return \%eager;
}

# Chunk 19.3: an identity of a connected preload STAGE peer (any 'preload-<name>'
# except the preload-root handshake peer). Every stage is forked from the base and
# so inherits the full merged preload meta (with its file_stage callbacks), so ANY
# live stage can resolve a file's stage. The base stage's own name varies ('base'
# for a staged preload, 'default' for a non-staged one), so we never hardcode it.
sub _resolver_identity {
    my $self = shift;

    my $peers = $self->{service_peers} or return undef;
    for my $id (sort keys %$peers) {
        next if $id eq 'preload-root';
        next unless $id =~ m/^preload-/;
        my $conn = $peers->{$id};
        next unless $conn && !$conn->closed;
        return $id;
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

# Chunk 19.3: resolve a test file's stage via a live preload stage -- the only kind
# of process holding the merged preload meta (and its file_stage callbacks). The
# scheduler-only runner has no preloader, so it asks a stage over the channel that
# stage registered and caches the answer per file. Returns the resolved stage name,
# or undef when no stage is reachable (the caller falls back to the default stage).
sub resolve_file_stage {
    my $self = shift;
    my ($file) = @_;

    my $cache = $self->{file_stage_cache} //= {};
    return $cache->{$file} if exists $cache->{$file};

    # The resolver is a live preload STAGE (not the preload-root). A stage can die
    # mid-resolve (a crash, a reload); request_preload_sync returns undef promptly
    # when its resolver's channel drops, so fail over to another live stage and
    # retry. Bounded by the number of mapped stages plus a little slack. Only a
    # successful resolution is cached -- a transient "no resolver" must not be
    # memoized, or a later run would keep the stale miss.
    my $state = $self->state;
    my $stage_count = $state ? scalar keys %{$state->stage_lifecycle // {}} : 0;
    my $attempts = $stage_count + 4;
    for (1 .. $attempts) {
        my $identity = $self->_resolver_identity or last;
        my $resp = $self->request_preload_sync($identity, 'resolve_file_stages', files => [$file]);
        return $cache->{$file} = $resp->{stages}->{$file}
            if $resp && $resp->{stages};

        # No answer (the resolver dropped); let service_io reap its closed channel so
        # the next _resolver_identity skips it, then retry against a survivor.
        $self->service_io;
    }

    return undef;
}

# Chunk 19.3: send a request to a preload peer and pump the service loop until its
# correlated response arrives (or a timeout). Used by the scheduler-only runner to
# resolve file_stage from the base stage synchronously during scheduling. Matched
# responses are stashed by request_id in service_on_response.
sub request_preload_sync {
    my $self = shift;
    my ($identity, $command, %args) = @_;

    my $conn = $self->service_peer_conn($identity) or return undef;
    my $request_id = $conn->send_request($command, %args);

    $self->{preload_responses} //= {};

    my $deadline = time + 30;
    until (exists $self->{preload_responses}->{$request_id}) {
        return undef if time > $deadline;
        $self->service_io;
        # The peer answering this request can die mid-resolve (a stage crash /
        # reload). Once service_io has reaped its closed channel, bail promptly so
        # the caller can fail over to another live peer instead of spinning to the
        # 30s deadline.
        return undef if $conn->closed;
        Time::HiRes::sleep(0.01);
    }

    return delete $self->{preload_responses}->{$request_id};
}

# Role::Service hands matched responses here; the scheduler-only runner stashes them
# by request id for request_preload_sync (resolve_file_stages).
sub service_on_response {
    my $self = shift;
    my ($conn, $event) = @_;

    ($self->{preload_responses} //= {})->{$event->{request_id}} = $event->{payload};

    return;
}

# Chunk 19.3: the scheduler-only runner cannot bucket a preload task by stage until
# the stage map is reported AND the base stage (the file_stage resolver) is
# connected -- task_stage resolves through both. A command may submit its run +
# tasks before the preload-root finishes its handshake and the base stage registers.
sub _ready_to_schedule {
    my $self = shift;

    return 1 unless $self->_preload_root_hosts_stages;
    return 0 unless $self->has_reported_stage_data;
    return 0 unless $self->_resolver_identity;

    return 1;
}

# Chunk 19.3: true if the preload-root process has exited (reaped here, since it is
# not in {+PROCS}). Used while waiting for stages to register so a preload-root that
# dies outright does not hang the run until the deadline.
sub _preload_root_dead {
    my $self = shift;

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

# Chunk 19.3: surface the preload-root's (and its stages') captured STDERR when the
# preloads fail to come up, so the broken-preload diagnostic (a die in a preload, a
# stage that did not exit cleanly) reaches the command's output instead of being
# swallowed in the preload-root's events file. Best-effort: any read error is
# ignored.
sub _emit_preload_failure_output {
    my $self = shift;

    # Prefer the warnings the preload-root handed us with stage_host_exited (no
    # events-file read race); these carry the broken-preload diagnostic.
    my $errors = $self->stage_host_errors;
    if ($errors && @$errors) {
        print STDERR $_ for @$errors;
        return;
    }

    require Test2::Collector::Util::Zstd::FrameBuffer;

    my @files = (File::Spec->catfile($self->{+DIR}, 'preload-root-events.jsonl.zst'));
    push @files => glob(File::Spec->catfile($self->{+DIR}, 'stage-*-events.jsonl.zst'));

    for my $file (@files) {
        next unless -f $file;

        my $ok = eval {
            my $fb = Test2::Collector::Util::Zstd::FrameBuffer->new;
            open(my $fh, '<', $file) or return 1;
            binmode $fh;
            local $/;
            my $data = <$fh>;
            close($fh);
            $fb->push_bytes($data);

            while (my $rec = $fb->next_frame) {
                my $facets = $rec->{payload}->{facet_data} or next;
                for my $info (@{$facets->{info} // []}) {
                    next unless ($info->{tag} // '') eq 'STDERR';
                    my $details = $info->{details};
                    next unless defined $details && length $details;
                    print STDERR "$details\n";
                }
            }
            1;
        };
        warn $@ if !$ok && $@;
    }

    return;
}

# Chunk 19.3: apply a run/task submission, or buffer it until the scheduler is ready
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

# Chunk 19.3: replay buffered submissions in order once the scheduler is ready.
sub flush_submit_buffer {
    my $self = shift;

    my $buf = delete $self->{submit_buffer} or return;
    for my $item (@$buf) {
        my ($method, @args) = @$item;
        $self->state->$method(@args);
    }

    return;
}

# Chunk 19.1: spawn the preload-root process (Test2::Harness2::Preload) -- the
# separate process that holds the preloaded interpreter state, so the runner does
# not. It is fork+exec'd under its own non-test collector (recording its
# stdout/stderr to preload-root-events.jsonl.zst, the same wire form as the runner
# and job collectors) and dials runner.socket to handshake (get_preload_list +
# set_stage_data).
#
# It is tracked like an aux process (chunk 17): NOT in {+PROCS}, so it never blocks
# the runner's wait(all=>1); stop_preload_root tears it down at wind-down, and its
# collector watches the runner pid (ARCHITECTURE.md §4.1) as the backstop. The
# preload-root deliberately never exits on its own mid-run, so the runner's
# waitpid(-1) reaper never trips over it.
#
# 19.1 STANDS THE PROCESS UP ONLY: it handshakes then idles. Stage forking (19.2),
# the test-launch goto-file path (19.3), and removing the in-runner preload path
# (19.5) are separate substeps; here the existing in-runner preloader still runs
# the run, and this process is spawned-but-idle alongside it.
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
        watch_parent_pid   => $self->{+ROOTPID},
    );

    $self->{+PRELOAD_ROOT_PID} = $pid;

    # Chunk 19.3: the atomic flip. The preload-root now drives a stage-host Runner
    # (Preload::run_driver) that hosts EVERY stage (base/default/NOPRELOAD + named),
    # so this runner holds no preloaded state and hosts no stage in-process: it goes
    # scheduler-only (run_tests -> run_scheduler_only) and dispatches every started
    # task out over a stage's registered channel. Stage resolution comes from the
    # reported stage map + a resolve_file_stages round-trip to the base stage (the
    # scheduler-only runner has no loaded preloader). Only the real root sets this
    # (spawn_preload_root is root-only via _preload_root_wanted).
    $self->{+PRELOAD_ROOT_HOSTS} = 1;

    return $pid;
}

# Chunk 19.1: tear the preload root down at runner wind-down. Ask it to stop over
# the channel it dialed (pumping the socket so the request is delivered and it is
# reaped), then TERM->KILL+reap by pid as the backstop -- the aux-process teardown
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
        $self->service_io if $self->{+ROOTPID} == $$;
        last if waitpid($pid, POSIX::WNOHANG) == $pid;
        Time::HiRes::sleep(0.02);
    }

    # If it did not stop gracefully we must NOT kill the collector parent ($pid):
    # that collector's ChildMonitor (watch_parent_pid => this runner) is exactly
    # what kills the preload-root's exec'd child if the runner vanishes. Killing
    # the collector parent destroys that backstop and ORPHANS its child. Instead,
    # leave the collector parent alone and let the backstop fire: when this runner
    # process exits (right after teardown/stop below), the ChildMonitor sees the
    # runner gone, terminates the preload-root child (and its stage descendants),
    # and the collector parent finalizes and exits -- reaped by init. The
    # preload-root is tracked OUTSIDE {+PROCS} (so it never trips the
    # waitpid(-1) reaper), and it is still alive here, so a non-blocking reaper
    # sees no dead child to choke on.
    delete $self->{+PRELOAD_ROOT_PID};

    return;
}

# Chunk 5g: the runner is the transient completion/stalled/timeout authority now
# that the yath-side gatherer is retired on the transient path. The watchdog folds
# the gatherer's non-walking duties (stalled-job detection, abort-on-wind-down)
# into the scheduler tick over canonical state. The standing gatherer survives
# only for the gated persistent path.
sub watchdog {
    my $self = shift;
    return $self->{+WATCHDOG} //= Test2::Harness2::Runner::Watchdog->new(runner => $self);
}

# Chunk 9: the stage child dials the runner's one service channel. runner.socket is
# the global flat socket in the workdir (bound by the root long before any stage
# forks), so a single connect normally succeeds; retry briefly in case the stage
# forked during a momentary accept gap. The dialed connection joins this process's
# service set, so the runner's dispatches (run_task / stop) are read off it and the
# stage's reports ride back up it -- one channel both ways (ARCHITECTURE.md §5.2).
sub _connect_runner {
    my $self = shift;

    my $path  = File::Spec->catfile($self->{+DIR}, 'runner.socket');
    my $start = time();

    while (1) {
        return 1 if $self->service_connect_peer('runner', $path);
        croak "Timed out connecting to runner.socket from stage '$self->{+STAGE}'"
            if (time() - $start) > 30;
        sleep 0.05;
    }
}

# Chunk 9: ask each transient stage service to shut down cleanly at run end. Stage
# children idle waiting for dispatches and never see the run end on their own, so
# the root must tell them. We send a graceful 'stop' down the SAME registered
# channel each stage opened to us, to every stage still tracked as a live process.
# A stage whose channel has already dropped (it exited -- a broken preload) has no
# peer connection and is skipped. TERM/KILL escalation for any straggler is left to
# the runner's normal stop() path.
sub stop_stages {
    my $self = shift;

    # Map each still-tracked stage process to its stage name so we stop exactly the
    # live stages (including nested children) over their own channels.
    my %live_stage;
    for my $proc (values %{$self->{+PROCS} // {}}) {
        next unless $proc->isa('Test2::Harness2::Runner::Preloader::Stage');
        $live_stage{$proc->name} = 1;
    }

    for my $stage (keys %live_stage) {
        eval { $self->service_send("preload-$stage", 'stop'); 1 };
    }

    return;
}

# Chunk 5d: hand started tasks bound for socketed stages out to those stages.
sub dispatch_pending {
    my $self = shift;

    return unless $self->{+ROOTPID} == $$;

    my $state      = $self->state;

    # When the preload-root hosts every stage there is NO in-process root stage,
    # so dispatch EVERY started task out over a stage socket (undef root_stage =>
    # take_dispatch_tasks dispatches all). This is LIVE for preload runs. The
    # in-runner staged-root path (else branch) keeps tasks for the root's own
    # stage in place for run_job; it is unreachable for preload runs.
    my $root_stage;
    if ($self->_preload_root_hosts_stages) {
        $root_stage = undef;
    }
    else {
        $root_stage = $self->{+STAGE} // return;
    }

    my @tasks = $state->take_dispatch_tasks($root_stage) or return;

    my $run_item = $state->run_item;

    for my $task (@tasks) {
        my $stage = $task->{stage};

        # Chunk 9: dispatch down the registered channel the stage opened to us
        # (service_send by peer identity), instead of dialing the stage's socket.
        # The stage is only schedulable after its stage_ready arrived on that
        # connection, so the peer normally exists; if the stage has since died its
        # connection dropped (EOF) and service_send reports no peer -- the same
        # "stage gone" signal the old connect-out client surfaced.
        my $sent = $self->service_send("preload-$stage", 'run_task', task => $task, run => $run_item);

        # take_dispatch_tasks already pulled this task off the list while it stays
        # tracked as RUNNING (slot + resources consumed). If the dispatch was a
        # no-op because the stage is gone, no stage will ever run it or report
        # stop_task/retry_task -- the job is stuck running forever and the run
        # hangs (clear_finished_run refuses to finish while RUNNING is nonzero).
        # Abort it NOW through the same machinery the watchdog uses on wind-down:
        # release its slot / resources and announce it as 'aborted' (failed) with a
        # diagnostic, instead of announcing a 'dispatched' that never happened.
        unless ($sent) {
            $self->watchdog->abort_job(
                $task->{job_id}, $task,
                "Stage '$stage' is gone; could not dispatch this job to it",
            );
            next;
        }

        # Chunk 5f: dispatching a job to a stage is a runner-originated state
        # mutation; forward it to subscribers so their mirror sees the job move.
        $self->announce_job($task->{job_id}, 'dispatched', stage => $stage, file => $task->{file}, run_id => $task->{run_id});
    }

    return;
}

sub run_tests {
    my $self = shift;

    # When the preload-root hosts every stage, this runner does NOT preload or
    # host a stage in-process -- it is scheduler-only. LIVE for preload runs:
    # _preload_root_hosts_stages is true once spawn_preload_root flipped it on.
    # The in-runner preload path below is only reached on the no-preload run.
    return $self->run_scheduler_only if $self->_preload_root_hosts_stages;

    my $preloader = $self->preloader;
    $preloader->preload();

    my ($stage, @procs) = $preloader->preload_stages();

    if ($self->dump_depmap) {
        if (my $dtrace = $preloader->dtrace) {
            if (my $depmap = $dtrace->dep_map) {
                my $file = "depmap-$stage.json";
                write_file($file, encode_json($depmap));
            }
        }
    }

    $self->watch($_) for @procs;

    while (1) {
        $self->{+CAN_STAGE} = 1;
        my $jump = setjump "Stage-Runner" => sub {
            $self->run_stage($stage);
        };

        last unless $jump;

        ($stage) = @$jump;
        $self->reset_stage();
    }

    return;
}

# The scheduler-only run loop for when the preload-root hosts every stage. This
# runner holds NO preloaded state and hosts NO stage: it only services
# runner.socket (accepting stage registrations + transitions + client requests)
# and ticks the in-process scheduler, which dispatches every started task out to a
# stage's registered channel (see dispatch_pending's preload-root branch). It does
# NOT touch the preloader (the preload-root owns preload + reload), does not
# run_job (stages fork the tests), and ends on a shutdown signal or run
# completion. LIVE for preload runs (reached from run_tests once
# _preload_root_hosts_stages is true).
sub run_scheduler_only {
    my $self = shift;

    # Chunk 19.3: wait until the preload-root has reported the stage map AND the base
    # stage (the file_stage resolver) is connected, so buffered run/task submissions
    # can be bucketed and resolved correctly. Submissions that arrive during this
    # window are buffered by submit_action; flush them once ready. If the preload-root
    # never becomes ready, wind down rather than hang.
    my $deadline = time + 60;
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

    while (1) {
        $self->service_io;
        $self->service_tick;

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

        Time::HiRes::sleep($self->{+WAIT_TIME}) if $self->{+WAIT_TIME};
    }

    # Synthesize an abort for any task still tracked as running whose stage never
    # reported completion, so the command-side driver rolls it up as failed rather
    # than "never ran" (the same wind-down duty the staged loop performs).
    $self->watchdog->abort_remaining unless $self->{+PERSIST};

    # Chunk 19.3b: the stages are children of the preload-root, not this runner, so
    # they are not in {+PROCS}; we only know them as registered `preload-<name>`
    # peers. The run is done, so tell every stage to stop over the channel it opened
    # to us. Once all stages stop, the preload-root's own stage-host run loop ends
    # and that process exits -- stop_preload_root then reaps it.
    $self->stop_preload_stages;

    return;
}

# Chunk 19.3b: send a graceful 'stop' to every connected preload stage peer
# (identities `preload-<name>`, excluding the preload-root's own handshake peer).
# Used on the scheduler-only path where the stages are the preload-root's children
# rather than this runner's, so stop_stages's {+PROCS} scan does not see them.
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

sub reset_stage {
    my $self = shift;

    # Normalize IPC
    $self->check_for_fork();

    # If no stage was set we do not want to clear this, root stages need to
    # preserve the preloads
    return unless $self->{+STAGE};

    # From Runner
    delete $self->{+STAGE};
    delete $self->{+STATE};
    delete $self->{+STAGE_DELEGATE};
    delete $self->{+LAST_TIMEOUT_CHECK};

    return;
}

sub run_stage {
    my $self = shift;
    my ($stage) = @_;

    $self->{+STAGE} = $stage;

    # A forked preload stage becomes a dispatch service: it drops the runner.socket
    # listen descriptor it inherited from the root and binds its own
    # preload-<stage>.socket (reserved for `yath spawn`, ARCHITECTURE.md §4.8). It
    # then opens the one registered service channel to the runner and announces
    # readiness over it (chunk 9, below), replacing the dispatch.jsonl-backed
    # stage_ready action.
    my $stage_service = $self->is_stage_service;
    if ($stage_service) {
        $self->reset_service;
        $self->start_service;

        # Chunk 9 (ARCHITECTURE.md §5.2): open the ONE registered service channel
        # to the runner and announce readiness over it. The stage dials runner.socket
        # (already bound long before any stage forks) and handshakes as
        # 'preload-<stage>'; the runner reads stage_ready / outcome reports off this
        # connection AND dispatches jobs back down it -- one bidirectional channel per
        # runner/stage pair, replacing the old two one-way channels (runner -> stage
        # dispatch socket + stage -> runner.socket report client). The stage still
        # binds its own preload-<stage>.socket, but it is reserved for `yath spawn`
        # (ARCHITECTURE.md §4.8), not used by the runner for dispatch.
        $self->_connect_runner;
        $self->service_send('runner', 'stage_ready', stage => $stage);
    }
    else {
        $self->state->stage_ready($stage);
    }

    while (1) {
        if ($self->{+ROOTPID} == $$) {
            # Root runner: accept run/task submissions and stage outcome reports on
            # runner.socket, and advance the in-process scheduler (which dispatches
            # ready tasks out to the stage sockets).
            $self->service_io;
            $self->service_tick;
        }
        elsif ($stage_service) {
            # Stage service: accept dispatched jobs on preload-<stage>.socket. No
            # scheduler here -- the runner schedules and dispatches; this process
            # only forks/reaps the jobs it is handed and reports outcomes back.
            $self->service_io;
            $self->{+SIGNAL} //= 'TERM' if $self->service_stopped;
        }

        next if $self->run_job();

        next if $self->wait();

        last if $self->end_test_loop();

        sleep($self->{+WAIT_TIME}) if $self->{+WAIT_TIME};
    }

    if ($stage_service) {
        # §6.8 (§4.7/§4.7a): a stage that exits while it is still in the stage map is
        # "coming back" -- the preload-root respawns it and the fresh incarnation
        # re-readies -- so it reports 'restarting', not 'down'. 'down' is reserved for
        # a stage that is absent from the map (driven map-side by set_stage_map), which
        # is the permanent "will never be available" signal. Whether the exit was an
        # intentional reload (SIGNAL=HUP) or another exit, the stage is still mapped and
        # coming back, so both restart.
        eval { $self->service_send('runner', 'stage_restarting', stage => $stage); 1 };
        $self->close_service;
    }
    else {
        $self->state->stage_restarting($stage);
    }

    # Chunk 5g: the run loop is ending; any task still tracked as running whose
    # collector never reported completion (e.g. a job dispatched to a stage that
    # died, or a job left over on a signal-driven shutdown) will never finish on
    # its own. Synthesize its abort into canonical state so the command-side
    # driver rolls it up as failed instead of reporting it as "never ran". Root
    # process / transient path only; the persistent gatherer owns this otherwise.
    $self->watchdog->abort_remaining
        if $self->{+ROOTPID} == $$ && !$self->{+PERSIST};

    # Chunk 5d/6.1-2: stage services (this process's own stage children, and a
    # nested stage's grandchildren) idle waiting for dispatches; unlike the old
    # dispatch.jsonl stages they do not observe the run ending on their own. Tell
    # each live child stage to shut down cleanly before the wait(all=>1) below, so
    # it does not block forever on an idle stage. This runs on the persistent path
    # too -- a persistent runner stops its stages when its run loop exits (shutdown
    # or reload-respawn).
    $self->stop_stages;

    $self->killall($self->{+SIGNAL}) if $self->{+SIGNAL};

    $self->wait(all => 1);

    exit 0 unless $stage eq 'base' || $stage eq 'default';
}

sub run_job {
    my $self = shift;

    my $task = $self->state->next_task($self->{+STAGE}) or return 0;

    if ($task->{spawn} && !$task->{resource_skip}) {
        my $job = Test2::Harness2::Runner::Spawn->new(
            runner        => $self,
            task          => $task,
            settings      => $self->settings,
            fork_callback => $self->{+FORK_SPAWN_CALLBACK},
        );

        $self->{+FORK_SPAWN_CALLBACK}->($self, $job);
        return 1;
    }

    my $run = $self->state->run();
    return 1 unless $run;

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

    my $spawn_time;

    my $pid;
    my $via = $job->via();
    if ($via) {
        require(mod2file($1)) if !defined(&{$via}) && $via =~ m/^(.+)::[^:]+$/;

        $spawn_time = time();
        $pid        = $self->$via($job);
        $job->set_pid($pid);
        $self->watch($job);
    }
    else {
        $spawn_time = time();
        $self->spawn($job);
        $pid = $job->pid;
    }

    # jobs.jsonl was the runner -> gatherer channel (the gatherer read it to learn
    # spawned jobs + their pids). Chunk 5g retired it on the transient path and
    # chunk 6.1 retires it on the persistent path: the runner forwards the
    # job-start as an announce_job mutation over the socket, and the job's pid
    # rides the new job_pid report / in-memory map (status/ps/abort), so no
    # process reads the file any more.

    # Chunk 5f: forking a test job is a runner-originated state mutation; forward
    # it to subscribers so their mirror sees the job go running.
    $self->announce_job($task->{job_id}, 'running', stage => $task->{stage}, file => $task->{file}, run_id => $task->{run_id});

    # Chunk 6.1-2: track the job's pid for the status/ps/abort report. The root
    # records it directly; a forked stage reports it back to the root over
    # runner.socket (the root is the job-pid authority), replacing the per-run
    # jobs.jsonl the status/ps commands used to read.
    if ($self->{+ROOTPID} == $$) {
        $self->record_job_pid($task->{job_id}, $pid);
    }
    else {
        # Chunk 9: the stage reports the forked job's pid back up its one registered
        # channel (the stage delegate's job_pid -> service_send('runner', ...)).
        eval { $self->state->job_pid($task->{job_id}, $pid); 1 };
    }

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

sub end_test_loop {
    my $self = shift;

    if ($self->orphaned) {
        $self->{+SIGNAL} //= 'TERM';
        return 1;
    }

    my $state = $self->state;

    no warnings 'uninitialized';
    if (!$self->{+STAGE} || $self->{+STAGE} eq 'default' || $self->{+STAGE} eq 'base') {
        $self->{+RESPAWN_RUNNER_CALLBACK}->()
            if $self->preloader->check($state) || ($self->{+SIGNAL} && $self->{+SIGNAL} eq 'HUP');
    }

    if ($self->preloader->check($state)) {
        $self->{+SIGNAL} //= 'HUP';
        return 1;
    }

    return 1 if $self->{+SIGNAL};

    return 1 if $state->done;

    return 0;
}

sub set_proc_exit {
    my $self = shift;
    my ($proc, $exit, $time, @args) = @_;

    if ($proc->isa('Test2::Harness2::Runner::Job')) {
        my $task = $proc->task;

        delete $self->{+JOB_PIDS}->{$task->{job_id}};

        my $timed_out = 0;
        if (!$exit && ref $self->{+RUN_REACHED_TIMEOUT} && $self->{+RUN_REACHED_TIMEOUT}->{$task->{job_id}}) {
            delete $self->{+RUN_REACHED_TIMEOUT}->{$task->{job_id}};
            $timed_out = 1;
        }

        if (($exit || $timed_out) && $proc->is_try < ($proc->retry // 0)) {
            $self->state->retry_task($task->{job_id});
            push @args => 'will-retry';
            # Chunk 5f: a root-forked job finishing is a runner-originated state
            # mutation; forward it so a subscriber's mirror sees it re-queued.
            $self->announce_job($task->{job_id}, 'retry', file => $task->{file}, run_id => $task->{run_id});
        }
        else {
            $self->state->stop_task($task->{job_id});
            $self->announce_job($task->{job_id}, 'done', file => $task->{file}, run_id => $task->{run_id});
        }

        if (my $bail = $exit ? $proc->bailed_out : 0) {
            print "$$ $0 BAIL-OUT detected: $bail\n";
            if ($self->settings->runner->abort_on_bail) {
                print "$$ $0 Aborting the test run...\n";
                $self->state->halt_run($task->{run_id});
            }
        }
    }
    elsif ($proc->isa('Test2::Harness2::Runner::Preloader::Stage')) {
        my $stage = $proc->name;

        # Chunk 9: a stage that exited (a reload/monitor relaunch, or a death) took
        # its end of the registered service channel with it. Drop the peer
        # connection so a relaunched stage's fresh dial registers cleanly and a
        # dispatch to a dead stage reports no-peer (handled as "stage gone") instead
        # of writing to a stale fd. A normal EOF already drops it; this covers the
        # reap-before-EOF ordering.
        if ($self->{+ROOTPID} == $$) {
            if (my $conn = $self->service_peer_conn("preload-$stage")) {
                $self->_drop_conn($conn);
            }
        }

        if ($exit != 0) {
            my $e   = parse_exit($exit);
            my $err = "$$ $0 Child stage '$stage' did not exit cleanly (sig: $e->{sig}, err: $e->{err})!\n";
            $self->{+MONITOR_PRELOADS} ? warn $err : die $err;
        }

        if ($self->{+MONITOR_PRELOADS} && $self->{+CAN_STAGE} && !$self->end_test_loop) {
            my $pid = $$;
            my ($name, @procs) = $self->preloader->_preload_stages($stage);
            $self->watch($_) for @procs;
            longjump "Stage-Runner" => $name unless $pid == $$;
        }
    }

    $self->SUPER::set_proc_exit($proc, $exit, $time, @args);
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

=item $coderef = $runner->respawn_runner_callback

Callback to restart the runner process.

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
