package Test2::Harness2::Runner;
use strict;
use warnings;

our $VERSION = '2.000000';

use File::Spec();

use Carp qw/confess croak/;
use POSIX qw/:sys_wait_h/;
use Long::Jump qw/setjump longjump/;
use Time::HiRes qw/sleep time/;

use Test2::Harness2::Util qw/clean_path file2mod mod2file parse_exit write_file_atomic process_includes chmod_tmp write_file collector_exit_code runner_events_file/;
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
        +can_stage
        <tmp_dir

        +scheduler_errors

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
    },
);

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
# Test2::Harness2::Role::Service nests a service's socket under runs/<run_ord>/
# when the consumer provides run_ord, so a per-run preload stage would bind
# runs/<run_id>/preload-<stage>.socket and two runs on one persistent runner
# could not collide. The runner deliberately does NOT define run_ord: execution
# is serialized (one active run) and preload stages are GLOBAL (shared,
# runner-lifetime, flat preload-<stage>.socket), so there is no per-run stage to
# scope or tear down. Implementing run_ord (+ a run-end stage teardown, +
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

# Test2::Harness2::IPC owns child reaping for this process (via wait /
# _bring_out_yer_dead, which dies on an unexpected waitpid). The service role's
# own reap_children would race that path, so it is disabled here: the runner
# polls the socket but reaps through IPC.
sub reap_children { my $self = shift; return }

our $RUNNER_PID;

sub init {
    my $self = shift;

    $self->{+ROOTPID} = $$;
    $RUNNER_PID = $$;

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

    my $preloader = $self->preloader;

    my $settings = $self->settings;
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
# task queue and a Runner::Client back to runner.socket for outcome reports.
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

        $self->{run_reached_timeout} //= {};
        $self->{run_reached_timeout}->{$job->task->{job_id}} = $pid;

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

    my $pidfile = File::Spec->catfile($self->{+DIR}, 'PID');
    write_file_atomic($pidfile, "$$");

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
    $self->start_service;

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

    $self->close_service;

    return $self->{+SIGNAL} ? 128 + $self->SIG_MAP->{$self->{+SIGNAL}} : $ok ? 0 : 1;
}

# Chunk 5g: final non-blocking sweep of the service socket so transitions that
# arrived after the run loop ended are folded into the monitor and forwarded to
# the subscriber before the socket closes (the command's completion signal).
sub _drain_transitions {
    my $self = shift;

    for (1 .. 50) {
        $self->service_io;
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
# path, 19_spec.md §6.14). Mirrors the below_threshold computation the in-runner
# preloader() already does.
sub _preload_root_wanted {
    my $self = shift;

    return 0 unless $self->{+ROOTPID} == $$;

    my $preloads = $self->{+PRELOADS} // [];
    return 0 unless @$preloads;

    return 0 if $self->{+PRELOAD_THRESHOLD} && $self->{+JOBS_TODO} && $self->{+PRELOAD_THRESHOLD} > $self->{+JOBS_TODO};

    return 1;
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

    my $pid = Test2::Collector::spawn_collector(
        is_test          => 0,
        name             => 'preload-root',
        exec             => \@cmd,
        recorder         => Test2::Collector::Recorder::Zstd->new(file => $events),
        watch_parent_pid => $self->{+ROOTPID},
    );

    $self->{+PRELOAD_ROOT_PID} = $pid;

    return $pid;
}

# Chunk 19.1: tear the preload root down at runner wind-down. Ask it to stop over
# the channel it dialed (pumping the socket so the request is delivered and it is
# reaped), then TERM->KILL+reap by pid as the backstop -- the aux-process teardown
# shape (it is not in {+PROCS}).
sub stop_preload_root {
    my $self = shift;

    my $pid = $self->{+PRELOAD_ROOT_PID} or return;

    eval { $self->service_send('preload-root', 'stop'); 1 };

    for (1 .. 100) {
        $self->service_io if $self->{+ROOTPID} == $$;
        last if waitpid($pid, POSIX::WNOHANG) == $pid;
        Time::HiRes::sleep(0.02);
    }

    if (kill(0, $pid)) {
        kill('TERM', $pid);
        for (1 .. 50) {
            last if waitpid($pid, POSIX::WNOHANG) == $pid;
            Time::HiRes::sleep(0.02);
        }
        if (kill(0, $pid)) {
            kill('KILL', $pid);
            waitpid($pid, 0);
        }
    }

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
    my $root_stage = $self->{+STAGE} // return;

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
        eval { $self->service_send('runner', 'stage_down', stage => $stage); 1 };
        $self->close_service;
    }
    else {
        $self->state->stage_down($stage);
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
        if (!$exit && ref $self->{run_reached_timeout} && $self->{run_reached_timeout}->{$task->{job_id}}) {
            delete $self->{run_reached_timeout}->{$task->{job_id}};
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
