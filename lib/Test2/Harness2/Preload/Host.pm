package Test2::Harness2::Preload::Host;
use strict;
use warnings;

our $VERSION = '2.000000';

use File::Spec();

use Carp qw/confess croak/;
use POSIX qw/:sys_wait_h/;
use Long::Jump qw/setjump longjump/;
use Time::HiRes qw/sleep time/;

use Test2::Harness2::Util qw/clean_path mod2file parse_exit process_includes chmod_tmp write_file/;
use Test2::Harness2::Util::JSON(qw/encode_json/);

use Test2::Harness2::Runner::Constants;

use Test2::Harness2::Runner::Run();
use Test2::Harness2::Runner::Job();
use Test2::Harness2::Runner::Spawn();
use Test2::Harness2::Runner::Preload();
use Test2::Harness2::Runner::Preloader();
use Test2::Harness2::Runner::StageProcess();
use Test2::Harness2::Runner::StageDelegate();

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

        <stage
        <signal

        +last_timeout_check
        +timeout_signaled
        +run_reached_timeout
        +can_stage
        <tmp_dir

        <rootpid

        +stage_delegate

        +job_pids

        +preload_warnings

        +pending_reload
    },
);

use Role::Tiny::With;
with 'Test2::Harness2::Role::Service';

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Preload::Host - The preload-root stage host (preload + launch
tests, no scheduler).

=head1 DESCRIPTION

This is the in-process stage host that the preload-root
(L<Test2::Harness2::Preload>) drives. It is a B<completely independent> class
from L<Test2::Harness2::Runner>: neither inherits from the other, and they share
only the L<Test2::Harness2::Role::Service> role (both have a listen socket and
manage connections).

Where the runner is the harness B<scheduler> -- it owns the canonical run State,
serves clients/stages over C<runner.socket>, and launches tests only as
clean-slate fork+exec -- the host has B<no scheduler> and B<no canonical run
State>. It preloads the user's libraries, forks/hosts the named preload stages,
dials the runner over C<runner.socket>, registers each stage, and launches the
tests it is dispatched (C<goto::file> in-process).

The host runs inside the preload-root process. Its C<rootpid> is the B<real
runner's> pid (never C<$$>): the base/default stage is hosted in THIS process and
the named stages are forked as its children; every stage is a socket-dispatch
service (binds C<< preload-E<lt>stageE<gt>.socket >>, dials C<runner.socket>, and
receives dispatched work + reports outcomes over the one registered channel it
opened to the runner).

=head1 SYNOPSIS

    # Built and driven by Test2::Harness2::Preload::_run_stage_host, never by hand.

=cut

sub job_class { 'Test2::Harness2::Runner::Job' }

# Every Preload::Host process is a forked preload stage acting as a socket-dispatch
# service (the base/default stage in the preload-root process, or a named stage
# forked from it). The root process keeps the 'runner' name / runner.socket; a
# stage rebinds the service socket to 'preload-<stage>.socket'.
sub name { 'runner' }

sub workdir { my $self = shift; return $self->{+DIR} }

sub service_name {
    my $self  = shift;
    my $stage = $self->{+STAGE} // return 'runner';
    return "preload-$stage";
}

# True once this process has become a forked preload stage (STAGE set). Before the
# run_stage loop sets STAGE it is the pre-stage host scaffold.
sub is_stage_service {
    my $self = shift;
    return $self->{+STAGE} ? 1 : 0;
}

sub init {
    my $self = shift;

    croak "'rootpid' is a required attribute (the real runner pid)"
        unless $self->{+ROOTPID};

    $self->{+JOB_PIDS} = {};

    croak "'dir' is a required attribute"      unless $self->{+DIR};
    croak "'settings' is a required attribute" unless $self->{+SETTINGS};

    my $dir = clean_path($self->{+DIR});

    croak "'$dir' is not a valid directory"
        unless -d $dir;

    $self->{+DIR} = $dir;

    $self->{+HANDLERS}->{HUP} = sub {
        my $sig = shift;

        # A direct SIGHUP to the preload-root reloads by re-execing the whole preload
        # tree. The base/default stage runs in this process and owns the
        # 'preload-root' Long::Jump frame, so it marks a pending reload and ends its
        # run loop; run_stage then respawns the tree. (`yath reload` does not take
        # this path -- it HUPs the runner, which forwards a reload over the
        # base/default stage's live socket channel instead.)
        print "$$ $0 ($self->{+STAGE}) Preload::Host caught SIG$sig, reloading...\n";
        $self->{+PENDING_RELOAD} = 1 unless $self->{+SIGNAL};
        $self->{+SIGNAL}         = $sig;
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

        # The real runner pid, so each stage collector watches it and
        # self-terminates if the runner dies (ARCHITECTURE.md §4.1).
        runner_pid => $self->{+ROOTPID},

        below_threshold => ($self->{+PRELOAD_THRESHOLD} && $self->{+JOBS_TODO} && $self->{+PRELOAD_THRESHOLD} > $self->{+JOBS_TODO}) ? 1 : 0,
    );
}

# The host never holds canonical scheduling State: every stage receives work over
# its own socket, and the runner decides each job's outcome from its collector's
# transitions + connection EOF (ARCHITECTURE.md §5.4) -- the stage reports no
# verdict. The lightweight in-stage delegate exposes the next_task/run API run_job
# calls, so the shared run loop is unchanged.
sub state {
    my $self = shift;
    return $self->stage_delegate;
}

# The lightweight in-stage delegate a forked preload stage uses in place of State.
# Built once per stage child; it holds the dispatched task queue and reports
# outcomes back to the runner via service_send over the single registered service
# channel (the connection the stage opened to send stage_ready).
sub stage_delegate {
    my $self = shift;
    return $self->{+STAGE_DELEGATE} //= Test2::Harness2::Runner::StageDelegate->new(
        workdir => $self->{+DIR},
        name    => $self->{+STAGE},
        runner  => $self,
    );
}

# Build the stage map reported to the runner from the merged preload meta the
# guarded preload produced: each user-defined stage name maps to whether it is the
# default. The runner resolves a test's stage client-side from the test's preload
# directives against this map, so the map only needs to say which stages exist and
# which is the default. Returns an empty hashref when there is no staged preload
# (the runner still needs the empty map to know the data has arrived).
sub stage_data {
    my $self = shift;

    my $meta = $self->preloader->staged;

    my $data = {};
    return $data unless $meta;

    my $lookup  = $meta->stage_lookup;
    my $default = $meta->default_stage;

    for my $name (keys %$lookup) {
        $data->{$name} = {
            default => (defined($default) && $name eq $default) ? 1 : 0,
        };
    }

    return $data;
}

# Stage-host request handlers. The runner (the scheduler) dispatches work to each
# stage over the one registered channel the stage opened to it; Role::Service's
# handle_request routes those commands to these handlers. These are the ONLY
# requests a stage host serves -- it does not own canonical State, so it has none
# of the runner's scheduler / state-hub handlers. (`stop` is handled by
# Role::Service itself.)

# The runner's scheduler dispatches an already-resolved task (resources merged) plus
# the run definition; the stage delegate queues it and the stage's run loop forks it
# from the preloaded interpreter. One-way: the runner does not read a reply.
sub request_handler_run_task {
    my $self = shift;
    my ($payload) = @_;
    $self->state->enqueue_task($payload->{task}, $payload->{run});
    return undef;
}

# `yath spawn` connects DIRECTLY to this stage's preload-<stage>.socket (bypassing
# the runner -- ARCHITECTURE.md §4.8) and requests a spawn: launch the user's
# script from THIS preloaded interpreter, attached to the command's real terminal,
# detached from the harness lifecycle. The request carries the command's listen
# socket path; the spawned side dials back to it and the command passes its real
# STDIN/STDOUT/STDERR over SCM_RIGHTS.
#
# This handler ACKs ({ok=>1}) WITHOUT blocking the host service loop: it
# double-forks + setsid's a detached SUPERVISOR (which holds the preloaded image,
# having forked from this preloaded stage) that does the dial-back, fd-receive,
# script-child fork, and exit-status reporting on its own. The host reaps the
# short-lived intermediate (pure zombie cleanup) and never watches the detached
# supervisor.
sub request_handler_spawn {
    my $self = shift;
    my ($payload, $conn) = @_;

    require Test2::Harness2::Runner::JobLauncher;

    my $spawn = $payload->{spawn} // {};

    my $file = $spawn->{abs_path} // $spawn->{file};
    return {ok => 0, error => 'spawn request missing a script path'}
        unless defined $file && length $file;

    return {ok => 0, error => 'spawn request missing the command listen_socket_path'}
        unless defined $spawn->{listen_socket_path} && length $spawn->{listen_socket_path};

    # Build the detached, non-collected spawn job from the request. ch_dir is the
    # command's cwd so a relative script path / __FILE__ resolves the way the user
    # expects; file is absolute so the goto::file launch opens it regardless of cwd.
    my $task = {
        spawn              => 1,
        file               => $file,
        ch_dir             => $spawn->{cwd},
        args               => $spawn->{args} // [],
        env_vars           => $spawn->{env_vars} // {},
        listen_socket_path => $spawn->{listen_socket_path},
        correlation_id     => $spawn->{correlation_id},
    };

    my $job = Test2::Harness2::Runner::Spawn->new(
        runner   => $self,
        task     => $task,
        settings => $self->settings,
    );

    # Double-fork + setsid so the supervisor detaches from the harness (reparents
    # away, survives runner/stage teardown -- ARCHITECTURE.md §4.8). The host reaps
    # ONLY the short-lived intermediate; the supervisor runs JobLauncher::launch_spawn,
    # which dials the command, receives its fds, forks the script child, and reports
    # the child's raw wait status over the control channel.
    my $intermediate = fork() // do {
        warn "$$ $0 spawn handler fork failed: $!";
        return {ok => 0, error => "spawn fork failed: $!"};
    };

    if ($intermediate) {
        $self->watch_pid($intermediate);
        return {ok => 1, correlation_id => $spawn->{correlation_id}};
    }

    # Intermediate: detach into a new session and fork the supervisor, then exit so
    # the supervisor is orphaned and reparents away.
    require POSIX;
    POSIX::setsid() or do { warn "spawn setsid failed: $!"; POSIX::_exit(1) };

    my $supervisor = fork();
    unless (defined $supervisor) {
        warn "spawn supervisor fork failed: $!";
        POSIX::_exit(1);
    }

    POSIX::_exit(0) if $supervisor;

    # The detached supervisor: drop the host's inherited service sockets so it holds
    # no dup of any peer connection (ARCHITECTURE.md §5.4), then run the supervisor
    # body. launch_spawn never returns.
    Test2::Harness2::Runner::JobLauncher->launch_spawn($self, $job, 'preload-root');
    POSIX::_exit(1);
}

# A monitored stage forwards a reload/monitor notification so the runner's reload
# state (diagnostics) stays current; the stage delegate relays it to the runner.
# One-way.
sub request_handler_reload {
    my $self = shift;
    my ($payload) = @_;
    $self->state->reload($payload->{stage}, $payload->{data});
    return undef;
}

# A `yath reload` (SIGHUP to the runner) is forwarded by the runner to the
# base/default stage's live channel -- the one connection serviced during a run --
# because the preload-root's own handshake channel is dormant mid-run. Translate it
# into the in-run respawn path: mark a pending reload and set SIGNAL=HUP so the
# base/default stage's run loop ends and respawns the whole preload tree (the same
# flow a monitored file change uses). A reload that races a shutdown is ignored: a
# queued `stop` (service_stopped) wins, so a stale reload cannot re-exec the tree
# during wind-down. One-way: the runner does not read a reply.
sub request_handler_reload_root {
    my $self = shift;

    return undef if $self->service_stopped;
    return undef if $self->{+SIGNAL};

    $self->{+PENDING_RELOAD} = 1;
    $self->{+SIGNAL}         = 'HUP';

    return undef;
}

sub check_timeouts {
    my $self = shift;

    return unless $self->settings->runner->use_timeout;

    my $now = time;

    # Check only once per second, that is as granular as we get.
    return if $self->{+LAST_TIMEOUT_CHECK} && $now < (1 + $self->{+LAST_TIMEOUT_CHECK});

    # The per-test silence and lifetime timeouts are enforced by the
    # Test2-Collector collector parent itself. What remains is a fallback for a
    # collector PARENT that should have exited but has not: once a job process has
    # been reaped (it is in WAITING) we give it a grace window, then escalate
    # TERM -> KILL so a wedged collector cannot hang the run.
    my $grace = $self->{+POST_EXIT_TIMEOUT} || 60;

    my $signaled = $self->{+TIMEOUT_SIGNALED} //= {};

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
        $self->killall($self->{+SIGNAL} // 'TERM');
        $self->wait(all => 1, timeout => 5);
    }

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
    die "Preload::Host caught SIG$sig. Attempting to shut down cleanly...\n";
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

    # The host does NOT write the workdir PID file (that names the real runner) and
    # does NOT bind runner.socket (the real runner owns it); its stages bind their
    # own preload-<stage>.socket in run_stage and dial the real runner.socket.

    # Propagate the workdir to every child (collectors, stages, jobs) so they can
    # locate runner.socket (ARCH 5.3).
    $ENV{T2_HARNESS_WORKDIR} = $self->{+DIR};

    $self->start();

    my $ok  = eval { $self->run_tests(); 1 };
    my $err = $@;
    $self->{+CAN_STAGE} = 0;

    warn $err unless $ok;

    $self->stop();

    return $self->{+SIGNAL} ? 128 + $self->SIG_MAP->{$self->{+SIGNAL}} : $ok ? 0 : 1;
}

# Ask each forked stage service to shut down cleanly at run end. Stage
# children idle waiting for dispatches and never see the run end on their own, so
# the host must tell them over the SAME registered channel each stage opened to the
# runner -- these are THIS host's own stage children, stopped via service_send to
# their peer identity.
sub stop_stages {
    my $self = shift;

    my %live_stage;
    for my $proc (values %{$self->{+PROCS} // {}}) {
        next unless $proc->isa('Test2::Harness2::Runner::StageProcess');
        $live_stage{$proc->name} = 1;
    }

    for my $stage (keys %live_stage) {
        eval { $self->service_send("preload-$stage", 'stop'); 1 };
    }

    return;
}

sub run_tests {
    my $self = shift;

    my $preloader = $self->preloader;

    # Load the preloads ONCE, here, under the test2_start_preload guard preload()
    # establishes -- so a preload's require-time Test2 side effects stay inside the
    # guard and no module loads twice (the preload-root handshake deliberately does
    # NOT pre-load them). Capture any preload-time warnings (on the persistent path a
    # broken preload is tolerated with a warn rather than a die) so the base stage can
    # forward them to the runner alongside the stage map -- otherwise they would never
    # reach a `yath run` client, since the persistent stage host does not exit.
    my @warnings;
    {
        local $SIG{__WARN__} = sub {
            push @warnings => $_[0];
            print STDERR $_[0];
        };
        $preloader->preload();
    }
    $self->{+PRELOAD_WARNINGS} = \@warnings;

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

# The stage child dials the runner's one service channel. runner.socket is
# the global flat socket in the workdir (bound by the real runner long before any
# stage forks). The dialed connection joins this process's service set, so the
# runner's dispatches (run_task / stop) are read off it and the stage's reports ride
# back up it -- one channel both ways (ARCHITECTURE.md §5.2).
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

sub reset_stage {
    my $self = shift;

    # Normalize IPC
    $self->check_for_fork();

    # If no stage was set we do not want to clear this, root stages need to
    # preserve the preloads
    return unless $self->{+STAGE};

    delete $self->{+STAGE};
    delete $self->{+STAGE_DELEGATE};
    delete $self->{+LAST_TIMEOUT_CHECK};

    return;
}

# A forked preload stage becomes a dispatch service: it drops the runner.socket
# listen descriptor it inherited and binds its own preload-<stage>.socket (reserved
# for `yath spawn`, ARCHITECTURE.md §4.8), opens the ONE registered service channel
# to the runner (ARCHITECTURE.md §5.2), and announces readiness over it. The base/
# default stage -- the one holding the full merged preload meta -- first reports the
# stage map (which stages exist + which is default) and any preload-time warnings,
# BEFORE its stage_ready: the runner gates dispatch on both the map AND the base
# stage being ready, so sending the map first guarantees it lands before any task is
# scheduled. Forked named stages inherit the same meta but must not re-report.
sub _announce_stage_ready {
    my $self = shift;
    my ($stage) = @_;

    $self->reset_service;
    $self->start_service;

    $self->_connect_runner;

    if ($stage eq 'base' || $stage eq 'default') {
        $self->service_send('runner', 'set_stage_data', stage_data => $self->stage_data);

        if (my $warnings = $self->{+PRELOAD_WARNINGS}) {
            $self->service_send('runner', 'preload_warnings', warnings => [@$warnings], want_reply => 0)    # one-way (#134 finding 106)
                if @$warnings;
        }
    }

    $self->service_send('runner', 'stage_ready', stage => $stage, want_reply => 0);    # one-way (#134 finding 106)

    return;
}

sub run_stage {
    my $self = shift;
    my ($stage) = @_;

    $self->{+STAGE} = $stage;

    my $stage_service = $self->is_stage_service;
    if ($stage_service) {
        $self->_announce_stage_ready($stage);
    }
    else {
        $self->state->stage_ready($stage);
    }

    while (1) {
        # Stage service: accept dispatched jobs on the registered channel. No
        # scheduler here -- the runner schedules and dispatches; this process only
        # forks/reaps the jobs it is handed and reports outcomes back.
        if ($stage_service) {
            $self->service_io;

            # A queued `stop` wins over a pending `yath reload`: drop the pending
            # reload and force a TERM shutdown so a stale reload cannot re-exec the
            # preload tree while the runner is winding down.
            if ($self->service_stopped) {
                delete $self->{+PENDING_RELOAD};
                $self->{+SIGNAL} = 'TERM';
            }
        }

        next if $self->run_job();

        next if $self->wait();

        last if $self->end_test_loop();

        sleep($self->{+WAIT_TIME}) if $self->{+WAIT_TIME};
    }

    if ($stage_service) {
        # §6.8 (§4.7/§4.7a): a stage that exits while it is still in the stage map is
        # "coming back" -- the preload-root respawns it and the fresh incarnation
        # re-readies -- so it reports 'restarting', not 'down'.
        eval { $self->service_send('runner', 'stage_restarting', stage => $stage, want_reply => 0); 1 };    # one-way (#134 finding 106)
        $self->close_service;
    }
    else {
        $self->state->stage_restarting($stage);
    }

    # Stage services (this process's own stage children, and a nested stage's
    # grandchildren) idle waiting for dispatches; tell each live child stage to shut
    # down cleanly before the wait(all=>1) below.
    $self->stop_stages;

    $self->killall($self->{+SIGNAL}) if $self->{+SIGNAL};

    $self->wait(all => 1);

    # A `yath reload` delivered mid-run reaches the base/default stage (it owns the
    # live channel during a run); respawn the whole preload tree from a clean
    # interpreter via the 'preload-root' Long::Jump host the preload-root launch
    # frame established, exactly as the post-run idle reload does. Only the
    # base/default stage runs in the preload-root process, so only it owns that jump
    # frame; named child stages exit and are relaunched by the respawned tree.
    if (delete $self->{+PENDING_RELOAD}) {
        longjump 'preload-root' => 'respawn';
    }

    exit 0 unless $stage eq 'base' || $stage eq 'default';
}

sub run_job {
    my $self = shift;

    my $task = $self->state->next_task($self->{+STAGE}) or return 0;

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

    my $pid;
    my $via = $job->via();
    if ($via) {
        require(mod2file($1)) if !defined(&{$via}) && $via =~ m/^(.+)::[^:]+$/;

        # The test-job launch double-forks + detaches the collector (ticket #28): it
        # returns the SHORT-LIVED INTERMEDIATE's pid, not the collector's. The stage
        # reaps ONLY the intermediate (pure zombie cleanup) and does NOT watch the
        # detached collector -- that re-parents to the runner subreaper (or init) and
        # the runner decides its outcome from the collector's transitions + EOF
        # (ARCHITECTURE.md §5.4). It is watched as a generic process (NOT the Job), so
        # set_proc_exit's Job branch never fires for it and no verdict is derived.
        $pid = $self->$via($job);
        $self->watch_pid($pid);
    }
    else {
        $self->spawn($job);
        $pid = $job->pid;

        # The spawn path is the stage's direct child; report its pid so the runner's
        # status/abort map has it. The detached test-job collector reports its own
        # pid to the runner over its handshake (ticket #28), so it is not reported
        # here.
        eval { $self->state->job_pid($task->{job_id}, $pid); 1 };
    }

    return $pid;
}

sub orphaned {
    my $self = shift;

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
        # Reaping a test-job collector is now pure zombie cleanup: the runner
        # decides the test's outcome (retry / stop / bail) from the collector's
        # transitions + connection EOF on runner.socket (ARCHITECTURE.md §5.4), not
        # from this reaped exit code. The stage therefore reports NO verdict back to
        # the runner -- doing so would double-decide. We only drop our local job-pid
        # bookkeeping and clear any timeout marker.
        my $task = $proc->task;
        delete $self->{+JOB_PIDS}->{$task->{job_id}};
        delete $self->{+RUN_REACHED_TIMEOUT}->{$task->{job_id}}
            if ref $self->{+RUN_REACHED_TIMEOUT};
    }
    elsif ($proc->isa('Test2::Harness2::Runner::StageProcess')) {
        my $stage = $proc->name;

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
