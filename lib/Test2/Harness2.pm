package Test2::Harness2;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use File::Path qw/make_path/;
use File::Spec ();
use Scalar::Util qw/blessed/;
use Time::HiRes qw/time/;
use Test2::Util::UUID qw/gen_uuid/;
use Test2::Harness2::Util qw/parse_exit tinysleep/;
use Test2::Harness2::Util::IPC qw/ipc_default_spawn_args/;
use POSIX qw/WNOHANG/;

use Atomic::Pipe;
use IPC::Manager qw/ipcm_spawn/;
use IPC::Manager::Service::Handle;
use Test2::Harness2::Collector;
use Test2::Harness2::Role::ResourceServiceHost;
use Test2::Harness2::Role::Service;
use Test2::Harness2::Run;
use Test2::Harness2::Run::State;
use Test2::Harness2::RunService;
use Test2::Harness2::Util::EventEmitter;

use Object::HashBase qw{
    <workdir
    <logdir
    <name
    <ipc_parent
    <job_id
    <test_auditor
    <kill_timeout
    <parent_pids
    <jump_to
    <resources
    <broken_resource_behavior
    <hash_seed
    state
    +queue
    +run_states
    +scheduler
    +running_jobs
    <resource_services
    +run_services
    <run_pids
    +run_flags
    <collector_grace_secs
    +pending_synth_completions
    +completed_runs
    +finish_after_initial_run
    +emitter
    +subscribers
    +subscriber_retry
    +run_ord_counter
    watch_pids
    own_pgroup
};

# Sentinel run_id key used by RUN_PIDS for processes that aren't bound
# to a particular run -- e.g. global resource services. Picked so it
# can never collide with a real run_id (which are uuids).
use constant RUN_PIDS_GLOBAL_KEY => '__global__';

# Valid values for broken_resource_behavior: what the scheduler does
# when a job needs a resource that has been flipped to
# permanent_broken. All three paths route the job through a real
# Collector launch so the on-disk artifacts match a real test's --
# see _launch_unavailable_action_job.
#
#   skip  - launch `perl -e 'use Test2::V0; skip_all ...'` so the
#           job's log looks like a regular test that called skip_all.
#   fail  - launch `perl -e 'die ...'` so the job's log looks like a
#           regular test that failed with an uncaught exception
#           (exit 255 with the message on stderr).
#   abort - same as fail for THIS job plus every remaining pending
#           job in the same run, one at a time as the job limiter
#           frees slots; the run closes out once they all complete.
use constant BROKEN_BEHAVIORS      => {map { $_ => 1 } qw/skip fail abort/};
use constant SUBSCRIBER_RETRY_CAP  => 1024;

# Grace window applied when a collector pid exits without a prior
# test_job_completed. The IPC::Manager loop drives run_on_interval
# every ~0.2s so the resolution is sub-second; the window itself is
# seconds-scale so a slow auditor finishing its emit gets a fair
# chance to land before the harness synthesizes a fail.
use constant DEFAULT_COLLECTOR_GRACE_SECS => 10;

use Role::Tiny::With;
with 'Test2::Harness2::Role::Service', 'Test2::Harness2::Role::ResourceServiceHost';

# Role::ResourceServiceHost scope hooks: the harness is the global
# host, so its scope is 'global' and no Run is bound to it.
sub service_host_scope { 'global' }
sub service_host_run   { undef }

# Resource-service log files live under the harness's logdir
# ($workdir/logs/ by default), not directly under $workdir.
sub service_host_logdir { $_[0]->{+LOGDIR} }

# The harness service acts as a subreaper so reparented descendants
# (double-forked tests, tests that setsid + exit their parent) still
# land inside perform_hard_stop's reach on shutdown.
sub become_sub_reaper { 1 }

sub init {
    my $self = shift;

    my $wd = $self->{+WORKDIR} // croak "'workdir' is a required attribute";
    croak "workdir '$wd' does not exist or is not a directory" unless -d $wd;

    # logdir defaults to 'logs' under the workdir. A caller-supplied
    # relative path is resolved under the workdir; an absolute path is
    # used verbatim (File::Spec handles non-unix absolute shapes like
    # 'C:\...' and UNC paths, so we do not just check for a leading /).
    # An existing empty directory is accepted -- only a non-empty
    # logdir clobbers prior output and is refused.
    my $logdir = $self->{+LOGDIR} // 'logs';
    $logdir = File::Spec->catdir($wd, $logdir)
        unless File::Spec->file_name_is_absolute($logdir);
    $self->{+LOGDIR} = $logdir;

    if (-e $logdir) {
        croak "logdir '$logdir' exists but is not a directory" unless -d $logdir;
        opendir(my $dh, $logdir) or croak "Cannot read logdir '$logdir': $!";
        my @entries = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
        closedir $dh;
        croak "logdir '$logdir' is not empty -- refusing to clobber"
            if @entries;
    }

    make_path("$logdir/services");

    $self->{+NAME}              //= 'harness';
    $self->{+JOB_ID}            //= gen_uuid();
    $self->{+KILL_TIMEOUT}      //= 15;
    $self->{+PARENT_PIDS}       //= [];
    $self->{+STATE}             //= 'running';
    $self->{+QUEUE}             //= [];
    $self->{+RUN_STATES}        //= {};
    $self->{+SCHEDULER}         //= {};
    $self->{+RUNNING_JOBS}      //= {};
    $self->{+RESOURCE_SERVICES} //= {};
    $self->{+RUN_SERVICES}      //= {};
    $self->{+RUN_PIDS}                 //= {};
    $self->{+RUN_FLAGS}                //= {};
    $self->{+PENDING_SYNTH_COMPLETIONS} //= {};
    $self->{+COLLECTOR_GRACE_SECS}     //= DEFAULT_COLLECTOR_GRACE_SECS;
    $self->{+COMPLETED_RUNS}    //= {};
    $self->{+WATCH_PIDS}        //= [@{$self->{+PARENT_PIDS}}];
    $self->{+OWN_PGROUP}        //= 0;
    $self->{+SUBSCRIBERS}       //= {};
    $self->{+SUBSCRIBER_RETRY}  //= {};

    # Sequential run-ord allocator: every accepted run gets the next
    # ordinal integer starting at 0. The counter is per harness-process;
    # persistent runners reuse the same harness so ords climb
    # monotonically across runs in a session, with gaps possible
    # (e.g. accepted-then-purged runs).
    $self->{+RUN_ORD_COUNTER}   //= 1;

    $self->{+BROKEN_RESOURCE_BEHAVIOR} //= 'skip';
    croak "invalid broken_resource_behavior '$self->{+BROKEN_RESOURCE_BEHAVIOR}' (want skip, fail, or abort)"
        unless BROKEN_BEHAVIORS->{$self->{+BROKEN_RESOURCE_BEHAVIOR}};

    $self->_init_resources;

    # Loggers / observers were removed; the collector now writes its
    # own spec/events/report files directly. Constructor args named
    # `loggers`, `service_loggers`, `test_loggers`, `extend_loggers`,
    # and `extend_test_loggers` are silently swallowed so legacy
    # callers do not crash, but they have no effect on the on-disk
    # layout.
    delete $self->{loggers};
    delete $self->{service_loggers};
    delete $self->{test_loggers};
    delete $self->{extend_loggers};
    delete $self->{extend_test_loggers};

    # The test auditor default is still set here: a run-complete
    # pass/fail verdict is useless without it.
    $self->{+TEST_AUDITOR} //= 'Test2::Harness2::Collector::Auditor::Test';
}

sub _init_resources {
    my $self = shift;

    # The harness no longer mandates the presence of any resource class.
    # An empty resources list is a valid, unlimited-concurrency
    # configuration. Auto-injection of a default JobCount happens at
    # the yath-test layer (App::Yath2::Options::Resource), not here, so
    # callers that construct a harness directly remain in full control
    # of which limiters (if any) participate.
    $self->{+RESOURCES} //= [];
}

#-------------------------------------------------------------------
# Per-run pid bookkeeping. RUN_PIDS keys every harness-spawned
# subprocess (run service, test collector, resource service) by the
# run_id it serves -- with a sentinel key for processes that aren't
# bound to a run (currently: global resource services). The maps are
# the single source of truth for per-run signal/kill/wait operations
# (helpers below). They are populated alongside the existing per-kind
# tracking hashes (RUN_SERVICES, RUNNING_JOBS, RESOURCE_SERVICES) and
# do not replace them in this stage; callers can keep using the
# kind-specific maps where they already do.
#
# Entry shape:
#   $self->{+RUN_PIDS}->{$run_id}->{$pid} = {
#       kind         => 'collector' | 'run_service' | 'resource_service',
#       started_at   => $epoch,
#       # per-kind metadata:
#       job_id       => $job_id,        # collector
#       job_try      => $job_try,       # collector
#       res_name     => $resource_name, # resource_service
#       res_svc      => $service_name,  # resource_service
#   };
#-------------------------------------------------------------------

sub _register_run_pid {
    my ($self, $run_key, $pid, %meta) = @_;
    return unless defined $run_key && length $run_key;
    return unless defined $pid && $pid > 0;
    $meta{started_at} //= time;
    $self->{+RUN_PIDS}->{$run_key}->{$pid} = \%meta;
    return $pid;
}

# Drop the (run_key, pid) entry. Returns the meta hash if it existed,
# or undef. Removes the per-run sub-hash entirely once it goes empty
# so iteration over active runs stays cheap.
sub _forget_run_pid {
    my ($self, $run_key, $pid) = @_;
    return unless defined $run_key && length $run_key;
    my $bucket = $self->{+RUN_PIDS}->{$run_key} or return;
    my $meta = delete $bucket->{$pid};
    delete $self->{+RUN_PIDS}->{$run_key} unless keys %$bucket;
    return $meta;
}

# Reverse-lookup: given a pid, return ($run_key, \%meta). The map is
# small (active runs * active pids), so a linear scan is fine. Returns
# (undef, undef) when not found.
sub _run_for_pid {
    my ($self, $pid) = @_;
    my $rp = $self->{+RUN_PIDS} // {};
    for my $run_key (keys %$rp) {
        my $meta = $rp->{$run_key}->{$pid};
        return ($run_key, $meta) if $meta;
    }
    return (undef, undef);
}

sub _pids_for_run {
    my ($self, $run_key) = @_;
    return () unless defined $run_key && length $run_key;
    my $bucket = $self->{+RUN_PIDS}->{$run_key} or return ();
    return keys %$bucket;
}

# Send $signal to every pid bound to $run_key. Skips pids that no
# longer exist. Returns the count of signals successfully delivered.
sub _kill_run {
    my ($self, $run_key, $signal) = @_;
    $signal //= 'TERM';
    my @pids = $self->_pids_for_run($run_key) or return 0;
    my $sent = 0;
    for my $pid (@pids) {
        next unless kill 0 => $pid;
        $sent++ if kill $signal => $pid;
    }
    return $sent;
}

# Block (with periodic 20ms naps) until every tracked pid for $run_key
# has exited the RUN_PIDS map, or until $deadline (epoch seconds).
# Returns 1 if the run drained, 0 on timeout. Note: this method only
# *waits* -- it does not reap. The reap path (run_on_pid) is what
# actually removes entries from RUN_PIDS, which only fires when the
# IPC::Manager loop services SIGCHLD.
sub _await_run_exit {
    my ($self, $run_key, $deadline) = @_;
    $deadline //= time + ($self->{+KILL_TIMEOUT} // 15);
    while ($self->_pids_for_run($run_key)) {
        return 0 if time >= $deadline;
        tinysleep(0.02);
    }
    return 1;
}

# ResourceServiceHost notification hooks: mirror every resource
# service registration into RUN_PIDS keyed by run_id, or by
# RUN_PIDS_GLOBAL_KEY for global services.
sub _resource_service_tracked {
    my ($self, %p) = @_;
    my $scope   = $p{scope} // 'global';
    my $run_key = ($scope eq 'run' && ref $p{run})
        ? $p{run}->run_id
        : RUN_PIDS_GLOBAL_KEY;
    my $svc = $self->{+RESOURCE_SERVICES}->{$p{pid}} || {};
    $self->_register_run_pid(
        $run_key, $p{pid},
        kind     => 'resource_service',
        res_name => $p{resource} ? $p{resource}->resource_name : undef,
        res_svc  => $p{name},
        scope    => $scope,
        ($svc->{started_at} ? (started_at => $svc->{started_at}) : ()),
    );
    return;
}

sub _resource_service_forgotten {
    my ($self, %p) = @_;
    my $scope   = $p{scope} // 'global';
    my $run_key = ($scope eq 'run' && ref $p{run})
        ? $p{run}->run_id
        : RUN_PIDS_GLOBAL_KEY;
    $self->_forget_run_pid($run_key, $p{pid});
    return;
}

sub start {
    my ($class, %args) = @_;

    my $test_run     = delete $args{test_run};
    my $finish_after = delete $args{finish_after_initial_run};
    my $caller_pid   = $$;

    $args{parent_pids} //= [$caller_pid];

    # If ipcm_info was already provided (e.g. by spawn()), reuse it.
    # Otherwise spawn a fresh IPC bus now.  Keep $ipcm_guard alive for the
    # rest of start() so the IPC bus is not torn down before the service
    # process connects.  POSIX::_exit bypasses Perl destructors, so the
    # guard never fires in either the service child or the collector parent.
    my $ipcm_guard;
    unless ($args{ipcm_info}) {
        $ipcm_guard = ipcm_spawn(ipc_default_spawn_args());
        $args{ipcm_info} = $ipcm_guard->info;
    }

    # Construct the service object in the pre-fork process.  init() creates
    # $workdir/logs/services/.
    my $self = $class->new(%args);

    # Everything the interpose child needs to do after the pipes are wired up
    # is packaged here so it can either run inline (the normal path) or be
    # handed to a caller-provided Long::Jump point via jump_to.
    my $run_service = sub {
        # The EventEmitter defaults wrap STDOUT and, when
        # T2_HARNESS2_PIPE_COUNT advertises separate pipes, STDERR for the
        # sync marker. The interposing collector is responsible for
        # publishing that env var (see Collector::_interpose_child). We
        # use the process-wide cached instance so anything else in this
        # service that emits (e.g. a formatter running in the same
        # process) shares one wrapper around the real FDs.
        $self->{+EMITTER} = Test2::Harness2::Util::EventEmitter->std;

        if ($test_run) {
            $self->request_handler_queue_test_run($test_run);
            $self->{+FINISH_AFTER_INITIAL_RUN} = 1 if $finish_after;
        }

        my $exit = $self->run;
        POSIX::_exit($exit // 0);
    };

    my $jump_to = $self->{+JUMP_TO};

    # The interpose collector has no parent service to notify -- it
    # is the top of its own tree. ipc_parent stays undef. ipc_harness
    # points at the service-side name so the collector identifies its
    # owning service even though it has no upward IPC peer. bus_id is
    # passed explicitly because the harness's own collector has no
    # parent to derive from.
    Test2::Harness2::Collector->interpose(
        type        => 'Service',
        id          => $self->{+NAME},
        logdir      => $self->{+LOGDIR},
        ipcm_info   => $self->ipcm_info,
        ipc_parent  => undef,
        ipc_run     => undef,
        ipc_harness => $self->{+NAME},
        bus_id      => "collector:service:" . $self->{+NAME},
        parser      => 'Test2::Harness2::Collector::Parser::IOParser',
        parent_pids => [$caller_pid],
        spec        => {service_name => $self->{+NAME}, role => 'harness'},
        (defined($jump_to) ? (jump_to => $jump_to, jump_payload => $run_service) : ()),
    );

    # Reached only in the interpose child on the non-jump path; with jump_to
    # set the longjump has already handed $run_service to the setjump caller.
    $run_service->();
}

sub spawn {
    my ($class, %args) = @_;

    my $test_run     = delete $args{test_run};
    my $finish_after = delete $args{finish_after_initial_run};
    my $protocol     = delete $args{protocol};

    $args{parent_pids} //= [$$];

    # Spawn the IPC bus in the parent so both parent and child share the same
    # connection info.  Use guard => 0 so the parent does not try to tear down
    # the bus when the Spawn object goes out of scope; the child owns it.
    # Caller-supplied $protocol is appended last so it overrides the default
    # protocol from ipc_default_spawn_args().
    my @ipcm_args = (ipc_default_spawn_args(), guard => 0);
    push @ipcm_args => (protocol => $protocol) if defined $protocol && length $protocol;
    my $ipcm = ipcm_spawn(@ipcm_args);
    $args{ipcm_info} = $ipcm->info;

    my $pid = fork // die "fork: $!";

    if ($pid) {
        # Parent: build the handle and block until the service is ready to
        # accept requests (same pattern as ipcm_service's post-fork wait).
        require Test2::Harness2::Spawn;
        my $handle = Test2::Harness2::Spawn->new(
            pid       => $pid,
            ipcm_info => $args{ipcm_info},
            workdir   => $args{workdir},
            name      => $args{name} // 'harness',
        );

        my $timeout = 10;
        my $start   = time;
        until ($handle->handle->ready) {
            die "Timeout waiting for harness service to come up after ${timeout}s\n"
                if time - $start > $timeout;

            tinysleep(0.02);
        }

        return $handle;
    }

    # Child: run the service via start().  ipcm_info is already set so
    # start() will skip the second ipcm_spawn() call.
    $class->start(
        %args,
        ($test_run     ? (test_run                 => $test_run)     : ()),
        ($finish_after ? (finish_after_initial_run => $finish_after) : ()),
    );

    # start() never returns; POSIX::_exit is called inside.
    POSIX::_exit(255);
}

# ipcm_info is stored as the bare 'ipcm_info' key (not a HashBase slot)
# because spawn/start flow passes it in through that name. The rest of
# the IPC::Manager::Role::Service contract (orig_io, pid, set_pid,
# watch_pids, handle_request) is provided by Role::Service.
sub ipcm_info { $_[0]->{ipcm_info} }

sub request_handler_queue_test_run {
    my ($self, $payload) = @_;
    $payload //= {};

    return {ok => 0, error => 'service not accepting new runs'}
        if $self->{+STATE} ne 'running';

    my $files = $payload->{files} || [];
    return {ok => 0, error => "'files' must be a non-empty arrayref"}
        unless ref($files) eq 'ARRAY' && @$files;

    # Logger options were dropped. Strip them from the payload so the
    # Run constructor never sees them. Kept as a tidy filter so older
    # clients passing them don't fail the request.
    my %run_logger_opts;

    # --set-hash-seed (Phase 7.2): when both the harness and the
    # incoming run have an explicit seed, they must match. Any
    # global preload tied to the harness was spawned with the
    # harness's seed in PERL_HASH_SEED, and a run asking for a
    # different value cannot reuse those preload processes.
    #
    # When the harness has no seed (no global preload was set up
    # with a fixed seed) we accept any run-level seed: the run
    # service simply propagates it into PERL_HASH_SEED for that
    # run's test children. When the run has no opinion we accept
    # whatever the harness was started with -- the run's children
    # inherit the harness's seed via the test environment.
    #
    # TODO Phase 7.2 follow-up: once a Preload resource exists and
    # the harness can declare global preloads, tighten this so an
    # unset-vs-set status mismatch is also rejected (the preload's
    # hash table is already baked).
    my $run_seed     = $payload->{hash_seed};
    my $harness_seed = $self->{+HASH_SEED};
    if (defined($run_seed) && length $run_seed && defined($harness_seed) && length $harness_seed) {
        return {ok => 0, error => "--set-hash-seed=$run_seed on the run does not match --set-hash-seed=$harness_seed on the harness; preload was started with seed $harness_seed and cannot be reused"}
            if $run_seed ne $harness_seed;
    }

    # Allocate the next run ordinal up-front so we can hand it to
    # Run->from_files. A caller-supplied run_id is rejected: run ids
    # are owned by the harness and incoming payload values would
    # collide with the counter.
    return {ok => 0, error => "'run_id' is allocated by the harness; do not pass it"}
        if defined $payload->{run_id};

    my $run_id = $self->{+RUN_ORD_COUNTER}++;

    my $ok = eval {
        my $run = Test2::Harness2::Run->from_files(
            files     => $files,
            run_id    => $run_id,
            (defined $payload->{hash_seed} ? (hash_seed => $payload->{hash_seed}) : ()),
            %run_logger_opts,
        );
        push @{$self->{+QUEUE}} => $run;
        $self->{+RUN_STATES}->{$run->run_id} = Test2::Harness2::Run::State->new(
            run_id     => $run->run_id,
            created_at => $run->created_at,
            pending    => [map { $_->job_id } @{$run->jobs}],
        );
        $self->_scheduler_queue_run($run);
        1;
    };
    my $err = $@;
    return {ok => 0, error => "$err"} unless $ok;

    my $run = $self->{+QUEUE}->[-1];

    $self->emit_service_event(
        kind     => 'run_queued',
        run_data => $run->TO_JSON,
    );

    # job_queued events are emitted by the run service once it has
    # started, so the per-job lifecycle stream lives in the run's own
    # .jsonl and not in the harness's service log.

    return {ok => 1, run_id => $run->run_id};
}

sub request_handler_status {
    my $self = shift;

    my $queue = [
        map {
            my $rs = $self->{+RUN_STATES}->{$_->run_id};
            {
                run_id  => $_->run_id,
                pending => $rs ? [@{$rs->pending}] : [],
                running => $rs ? [@{$rs->running}] : [],
                done    => $rs ? [@{$rs->done}]    : [],
            }
        } @{$self->{+QUEUE}}
    ];

    my @running = map {
        my $cur = $_;
        {
            run_id    => $cur->{run}->run_id,
            job_id    => $cur->{job}->job_id,
            test_file => $cur->{job}->test_file_rel,
            pid       => $cur->{pid},
            started   => $cur->{started_at},
        };
    } values %{$self->{+RUNNING_JOBS}};

    my @resources = map { $_->status } @{$self->{+RESOURCES}};

    return {
        service => {
            name    => $self->{+NAME},
            pid     => $$,
            job_id  => $self->{+JOB_ID},
            workdir => $self->{+WORKDIR},
            state   => $self->{+STATE},
        },
        queue     => $queue,
        running   => \@running,
        resources => \@resources,
    };
}

sub request_handler_finish {
    my $self = shift;
    return {ok => 0} unless $self->{+STATE} eq 'running';
    $self->{+STATE} = 'finishing';
    return {ok => 1};
}

# Idle-check used by the test command (and any caller that wants to
# wait for the harness to drain before requesting termination).
# Returns {ok => 1, idle => 1} when there is no other pending work
# the harness still needs to do for the asking peer:
#
#   - the harness's outbox to that peer is empty
#   - no runs are active or queued
#   - no in-flight subscription deltas remain
#
# The current request itself is NOT counted: the response that goes
# back is queued AFTER this handler returns, so at handler-time the
# outbox does not yet contain it. The caller therefore polls until
# idle == 1, then issues finish/terminate without racing pending
# events.
sub request_handler_has_pending_messages {
    my ($self, $payload, $msg) = @_;

    my $peer = $payload->{peer} // ($msg ? $msg->from : undef)
        or return {ok => 0, error => "'peer' is required (or supply a from-bearing msg)"};

    my $client = $self->client;

    # IPC::Manager 0.000034 (cpanfile minimum) provides the full
    # Outbox API as no-op fallbacks on every client backend, so
    # pending_sends_to is always callable -- non-Outbox clients
    # return 0 without walking anything.
    my $pending = $client->pending_sends_to($peer);

    my $running = scalar keys %{$self->{+RUN_SERVICES} // {}};
    my $queued  = scalar @{$self->{+QUEUE}             // []};

    return {
        ok      => 1,
        idle    => ($pending == 0 && $running == 0 && $queued == 0) ? 1 : 0,
        pending => $pending,
        running => $running,
        queued  => $queued,
    };
}

# Per-run pass/fail + per-job verdicts. A completed run's final
# snapshot is stashed in COMPLETED_RUNS by _handle_run_state_update
# at the moment it sees the run close out; this handler serves from
# that cache. A still-running run returns state => 'running' with
# no pass/fail so callers can poll.
sub request_handler_run_results {
    my ($self, $payload) = @_;

    my $run_id = $payload->{run_id};
    return {ok => 0, error => "'run_id' is required"}
        unless defined $run_id;

    if (my $info = $self->{+COMPLETED_RUNS}->{$run_id}) {
        return {ok => 1, %$info};
    }

    if (grep { $_->run_id eq $run_id } @{$self->{+QUEUE} // []}) {
        return {ok => 1, state => 'running', run_id => $run_id};
    }

    return {ok => 0, error => "unknown run '$run_id'"};
}

sub run_on_general_message {
    my ($self, $msg) = @_;

    # Drain any pending retries at the top of each message tick so
    # temporary send failures resolve promptly when the bus catches up.
    $self->_drain_subscriber_retries;

    my $content = $msg->content;
    my $kind    = ref($content) eq 'HASH' ? $content->{kind} : undef;

    # The act of receiving this message has already woken the service's event
    # loop. On the next run_on_all iteration the scheduler re-ticks. Nothing
    # else to do.
    return if defined $kind && $kind eq 'job_complete_notify';

    # Run-service aggregation: the run service owns the authoritative
    # Run state and sends us a full-snapshot mutation on every change.
    # We mirror it into the Run we're tracking so the scheduler sees
    # the same pending / running / done the run service sees.
    return $self->_handle_run_state_update($content)
        if defined $kind && $kind eq 'run_state_update';

    # Run-service aggregation: per-job release signal. The scheduler
    # needs resource release and a wake-up; the final verdict already
    # flowed through the run_state_update channel (and is logged in
    # the run's own jsonl, not here).
    return $self->_handle_job_release($content)
        if defined $kind && $kind eq 'job_release';

    return $self->_handle_resource_state_message($kind, $content)
        if defined $kind && $kind =~ m/^resource_(?:paused|resumed|ready|broken|permanent_broken)$/;

    # Per-job lifecycle. After Stage 4 of the RunService flatten the
    # auditor sends test_job_* events to the harness directly (the
    # collector's ipc_run was repointed). The harness owns Run::State
    # mutation and the run-level event emission that used to live in
    # RunService.
    return $self->_handle_test_job_started($content)
        if defined $kind && $kind eq 'test_job_started';

    return $self->_handle_test_job_diagnosing($content)
        if defined $kind && $kind eq 'test_job_diagnosing';

    return $self->_handle_test_job_failing($content)
        if defined $kind && $kind eq 'test_job_failing';

    return $self->_handle_test_job_completed($content)
        if defined $kind && $kind eq 'test_job_completed';

    # Lifecycle reflection from child collectors that route their
    # collector_start/_end up to the harness: run-service collectors
    # and global services. The harness collector itself has no parent
    # and skips emission entirely so we never receive its own pair.
    return $self->_handle_collector_start($content)
        if defined $kind && $kind eq 'collector_start';

    return $self->_handle_collector_end($content)
        if defined $kind && $kind eq 'collector_end';

    warn "Test2::Harness2: unhandled general message kind: " . (defined $kind ? "'$kind'" : '(none)') . "\n";

    return;
}

# Reflect a collector_start IPC (from a run-service collector or a
# global-service collector) into the harness's own outgoing event
# stream. The harness's own collector picks it up via the standard
# pipeline and writes a harness_collector_start row into
# services/harness/events.jsonl.zst. That row is the entry-point a
# Log iterator follows to descend into a run's or global service's
# events.jsonl.zst.
sub _handle_collector_start {
    my ($self, $content) = @_;
    return unless ref($content) eq 'HASH';

    my $em = $self->{+EMITTER} or return;
    # Emit as a top-level harness_collector_start facet (NOT nested
    # under facet_data.harness) so the Log iterator's depth-first walk
    # can detect it via $event->{facet_data}{harness_collector_start}.
    $em->emit_raw({
        facet_data => {
            harness_collector_start => {%$content},
        },
    });

    return;
}

sub _handle_collector_end {
    my ($self, $content) = @_;
    return unless ref($content) eq 'HASH';

    my $em = $self->{+EMITTER} or return;
    $em->emit_raw({
        facet_data => {
            harness_collector_end => {%$content},
        },
    });

    return;
}

#-------------------------------------------------------------------
# Per-job lifecycle handlers. These mutate RUN_STATES->{$run_id}
# in-process, emit a run-level lifecycle event onto the harness's
# own service event stream, and broadcast the new state snapshot to
# subscribed peers. They moved here from RunService when the auditor
# was redirected to talk to the harness directly.
#
# Per-run side state (first-fail latch, completed-job idempotency
# guard, per-job result snapshots that feed the eventual aggregate
# verdict) lives on RUN_FLAGS->{$run_id} so it stays scoped to the
# right run when multiple runs are active.
#-------------------------------------------------------------------

# Initialize / fetch the side-state hash for this run. Idempotent.
sub _run_flags {
    my ($self, $run_id) = @_;
    return $self->{+RUN_FLAGS}->{$run_id} //= {
        completed_job_ids    => {},
        completed_job_states => {},
        failing_emitted      => 0,
        pass                 => 1,
    };
}

sub _handle_test_job_started {
    my ($self, $content) = @_;
    return unless ref($content) eq 'HASH';

    my $run_id = $content->{run_id} // return;
    my $job_id = $content->{job_id} // return;

    my $rstate = $self->{+RUN_STATES}->{$run_id} //=
        Test2::Harness2::Run::State->new(run_id => $run_id);

    my $started_at = $content->{stamp} // time;

    # pending -> running. Out-of-order or duplicate started messages
    # are tolerated; mark_running is idempotent against running/done.
    my $ok  = eval { $rstate->mark_running($job_id); 1 };
    my $err = $@;
    warn "Test2::Harness2: could not mark job '$job_id' running for run '$run_id': $err"
        unless $ok;

    $rstate->seed_job_result($job_id, started_at => $started_at);

    $self->emit_service_event(
        kind     => 'job_started',
        stamp    => $started_at,
        run_id   => $run_id,
        job_info => {
            run_id  => $run_id,
            job_id  => $job_id,
            job_try => $content->{job_try},
        },
    );

    $self->_broadcast_run_state($run_id);
    return;
}

sub _handle_test_job_diagnosing {
    my ($self, $content) = @_;
    return unless ref($content) eq 'HASH';

    my $run_id = $content->{run_id} // return;
    $self->emit_service_event(
        kind     => 'job_diagnosing',
        stamp    => time,
        run_id   => $run_id,
        job_info => {
            run_id  => $run_id,
            job_id  => $content->{job_id},
            job_try => $content->{job_try},
        },
    );
    return;
}

sub _handle_test_job_failing {
    my ($self, $content) = @_;
    return unless ref($content) eq 'HASH';

    my $run_id = $content->{run_id} // return;
    $self->emit_service_event(
        kind     => 'job_failing',
        stamp    => time,
        run_id   => $run_id,
        job_info => {
            run_id  => $run_id,
            job_id  => $content->{job_id},
            job_try => $content->{job_try},
        },
    );

    my $flags = $self->_run_flags($run_id);
    unless ($flags->{failing_emitted}) {
        $flags->{failing_emitted} = 1;
        $flags->{pass}            = 0;
        $self->emit_service_event(
            kind    => 'run_failing',
            run_id  => $run_id,
            job_id  => $content->{job_id},
            job_try => $content->{job_try},
            stamp   => time,
        );
    }

    return;
}

sub _handle_test_job_completed {
    my ($self, $content) = @_;
    return unless ref($content) eq 'HASH';

    my $run_id = $content->{run_id} // return;
    my $job_id = $content->{job_id} // return;

    my $flags = $self->_run_flags($run_id);

    # Idempotent against the auditor + watchdog race: first wins.
    return if $flags->{completed_job_ids}{$job_id};
    $flags->{completed_job_ids}{$job_id} = 1;

    # Snapshot the full payload so the run-aggregate path can build
    # without disk reads.
    $flags->{completed_job_states}{$job_id} = {%$content};

    if (!$content->{pass} && !$flags->{failing_emitted}) {
        $flags->{failing_emitted} = 1;
        $flags->{pass}            = 0;
        $self->emit_service_event(
            kind    => 'run_failing',
            run_id  => $run_id,
            job_id  => $job_id,
            job_try => $content->{job_try},
            stamp   => time,
        );
    }

    my $rstate = $self->{+RUN_STATES}->{$run_id} //=
        Test2::Harness2::Run::State->new(run_id => $run_id);

    my $completed_at = $content->{stamp} // time;
    $rstate->record_job_result(
        $job_id,
        pass       => $content->{pass} ? 1 : 0,
        exit       => $content->{exit},
        codes      => $content->{codes},
        pass_count => $content->{pass_count},
        fail_count => $content->{fail_count},
        ($content->{times}              ? (times       => $content->{times})       : ()),
        ($content->{child_times}        ? (child_times => $content->{child_times}) : ()),
        (defined $content->{child_wall} ? (child_wall  => $content->{child_wall})  : ()),
        stamp        => $completed_at,
        completed_at => $completed_at,
    );

    my $ok  = eval { $rstate->mark_done($job_id); 1 };
    my $err = $@;
    warn "Test2::Harness2: could not mark job '$job_id' done for run '$run_id': $err"
        unless $ok;

    $self->emit_service_event(
        kind     => 'job_completed',
        stamp    => $content->{completed_at} // time,
        run_id   => $run_id,
        job_info => {
            run_id  => $run_id,
            job_id  => $job_id,
            job_try => $content->{job_try},
        },
        pass => $content->{pass},
    );

    $self->_broadcast_run_state($run_id);
    return;
}

# Emit the terminal run_completed + collector_report two-facet
# event from the harness's own emitter. Built from per-job state
# accumulated in RUN_FLAGS as test_job_completed messages came in.
# The renderer's harness_run_end synthesizer reads pass/fail counts
# off the collector_report facet (see Renderer::Driver line 295+).
sub _emit_run_completed {
    my ($self, $run) = @_;
    my $run_id = $run->run_id;

    my $flags = $self->{+RUN_FLAGS}->{$run_id} or return;
    return if $flags->{run_completed_emitted}++;

    my $em = $self->{+EMITTER} or return;

    my $now    = time;
    my $report = $self->_build_collector_report($run, $now);

    # Two-facet event: harness.run_completed (state-flip announcement)
    # + top-level collector_report (data the renderer consumes for
    # the aggregate verdict). emit_raw -- not emit_event -- so
    # collector_report lands at the top of facet_data, not nested
    # under harness.
    $em->emit_raw({
        facet_data => {
            harness => {
                run_id        => $run_id,
                run_completed => {
                    run_id => $run_id,
                    stamp  => $now,
                },
            },
            collector_report => $report,
        },
    });

    return;
}

# Walk RUN_FLAGS->{$run_id}{completed_job_states} (per-job state
# hashes captured at test_job_completed time) and assemble the
# run-level aggregate the renderer summarizes. Mirrors the
# previous RunService._build_collector_report.
sub _build_collector_report {
    my ($self, $run, $now) = @_;
    $now //= time;

    my $run_id = $run->run_id;
    my $flags  = $self->{+RUN_FLAGS}->{$run_id} //= {};
    my $states = $flags->{completed_job_states} // {};

    my $passed  = 0;
    my $failed  = 0;
    my $aborted = 0;

    my %jobs_by_id;
    for my $jid (keys %$states) {
        my $st       = $states->{$jid} // {};
        my $job_pass = $st->{pass} ? 1 : 0;
        if ($job_pass) {
            $passed++;
        }
        else {
            $failed++;
            $aborted++ if $st->{synth};
        }

        # Resolve test file from the Run's queue-time job spec.
        my $file = $st->{file};
        if (!defined $file) {
            for my $job (@{$run->jobs}) {
                next unless $job->job_id eq $jid;
                my $tf = $job->test_file;
                $file = $tf->absolute if $tf;
                last;
            }
        }

        my $tries = defined($st->{job_try}) ? $st->{job_try} : 1;
        $jobs_by_id{$jid} = {
            job_id   => $jid,
            file     => $file,
            pass     => $job_pass,
            tries    => $tries,
            subtests => [@{$st->{subtests} // []}],
        };
    }

    # Stable ordering: order from the Run's job spec; remaining ids
    # appended sorted so the array stays deterministic.
    my @ordered;
    my %placed;
    for my $job (@{$run->jobs}) {
        my $jid = $job->job_id;
        next unless exists $jobs_by_id{$jid};
        push @ordered, $jobs_by_id{$jid};
        $placed{$jid} = 1;
    }
    for my $jid (sort keys %jobs_by_id) {
        next if $placed{$jid};
        push @ordered, $jobs_by_id{$jid};
    }

    my $total = scalar @ordered;

    return {
        pass         => $flags->{pass}       ? 1 : 0,
        started_at   => $flags->{started_at},
        ended_at     => $flags->{ended_at}  // $now,
        total_jobs   => $total,
        passed_jobs  => $passed,
        failed_jobs  => $failed,
        aborted_jobs => $aborted,
        jobs         => \@ordered,
    };
}

# Push a snapshot of the named run's State out to subscribers AND
# trigger run-finalization if the run is now complete. This
# replaces the round-trip via run_state_update IPC that RunService
# used to drive: subscribers still see one snapshot per state
# change, just sourced locally instead of over the bus.
sub _broadcast_run_state {
    my ($self, $run_id) = @_;
    my $rstate = $self->{+RUN_STATES}->{$run_id} or return;
    my $data   = $rstate->TO_JSON;
    $self->_notify_state_subscribers($run_id, $data);

    my ($run) = grep { $_->run_id eq $run_id } @{$self->{+QUEUE} // []};
    $self->_finalize_run_if_complete($run) if $run;
    return;
}

# Peer delta callback from IPC::Manager. A negative delta on a
# subscribed peer IS the signal that the peer has left the bus --
# no separate peer_exists() query is needed. Clean unsubscribes
# have already removed the peer from SUBSCRIBERS, so anything that
# reaches this branch is an unexpected departure; we warn and drop
# the registration (plus any queued retries).
sub run_on_peer_delta {
    my ($self, $delta) = @_;

    return unless ref($delta) eq 'HASH';

    for my $peer (keys %$delta) {
        next unless $delta->{$peer} < 0;
        next unless exists $self->{+SUBSCRIBERS}->{$peer};

        warn "Test2::Harness2: subscriber '$peer' left without unsubscribing\n";
        delete $self->{+SUBSCRIBERS}->{$peer};
        delete $self->{+SUBSCRIBER_RETRY}->{$peer};
    }

    $self->_drain_subscriber_retries;
    return;
}

sub _handle_resource_state_message {
    my ($self, $kind, $content) = @_;

    my $name = ref($content) eq 'HASH' ? $content->{resource} : undef;
    return unless defined $name;

    my ($res) = grep { $_->resource_name eq $name } @{$self->{+RESOURCES} // []};
    return unless $res;

    if    ($kind eq 'resource_paused')           { $res->mark_paused }
    elsif ($kind eq 'resource_broken')           { $res->mark_broken }
    elsif ($kind eq 'resource_permanent_broken') { $res->mark_permanent_broken }
    elsif ($kind eq 'resource_resumed' || $kind eq 'resource_ready') {
        # Permanent brokenness is sticky; a resource cannot re-declare itself
        # ready once the harness has ruled it out.
        $res->mark_resumed unless $res->is_permanent_broken;
    }

    return;
}

# ----------------------------------------------------------------------
# Subscription API. Consumers (typically the test command) ask to
# be told when run state changes. The harness is the only service that
# carries this registry; run services publish state upstream via
# _send_to_harness, the harness then fans out to any matching
# subscribers.
#
# Registry shape:
#   { $peer_name => {
#         global => $bool,      # (future) harness-level state
#         runs   => { $id=>1 }, # run ids the subscriber watches
#         state  => $bool,      # want state change messages
#     } }
sub request_handler_subscribe {
    my ($self, $payload, $msg) = @_;

    my $peer = $msg ? $msg->from : undef;
    return {ok => 0, error => "subscribe requires an IPC message context"}
        unless defined $peer && length $peer;

    my $global = $payload->{global} ? 1 : 0;
    my $state  = $payload->{state}  ? 1 : 0;

    my @run_ids;
    push @run_ids => $payload->{run}     if defined $payload->{run};
    push @run_ids => @{$payload->{runs}} if ref($payload->{runs}) eq 'ARRAY';

    # Validate every run_id up front. The harness knows about runs in
    # the live queue and in COMPLETED_RUNS (terminal snapshots).
    for my $rid (@run_ids) {
        next if grep { $_->run_id eq $rid } @{$self->{+QUEUE} // []};
        next if $self->{+COMPLETED_RUNS}->{$rid};
        return {ok => 0, error => "unknown run '$rid'"};
    }

    my $entry = $self->{+SUBSCRIBERS}->{$peer} //= {
        global => 0,
        runs   => {},
        state  => 0,
    };
    $entry->{global}     ||= $global;
    $entry->{state}      ||= $state;
    $entry->{runs}->{$_} = 1 for @run_ids;

    # Send an initial state snapshot for each freshly-added run so the
    # subscriber does not need to separately request it.
    if ($state) {
        for my $rid (@run_ids) {
            $self->_send_state_snapshot($peer, run_id => $rid);
        }
    }

    return {ok => 1};
}

sub request_handler_unsubscribe {
    my ($self, $payload, $msg) = @_;

    my $peer = $msg ? $msg->from : undef;
    return {ok => 0, error => "unsubscribe requires an IPC message context"}
        unless defined $peer && length $peer;

    delete $self->{+SUBSCRIBERS}->{$peer};
    delete $self->{+SUBSCRIBER_RETRY}->{$peer};

    return {ok => 1};
}

# Fan-out. Called from _handle_run_state_update. Full snapshot each
# time; consumers diff on their side.
sub _notify_state_subscribers {
    my ($self, $run_id, $run_data) = @_;
    return unless defined $run_id;

    for my $peer (keys %{$self->{+SUBSCRIBERS}}) {
        my $entry = $self->{+SUBSCRIBERS}->{$peer};
        next unless $entry->{state};
        next unless $entry->{runs}->{$run_id};

        $self->_send_to_subscriber(
            $peer => {
                type   => 'state',
                item   => 'run',
                run_id => $run_id,
                state  => $run_data,
            },
        );
    }
    return;
}

sub _send_state_snapshot {
    my ($self, $peer, %params) = @_;
    my $run_id = $params{run_id} or return;

    my $run_data;
    if (grep { $_->run_id eq $run_id } @{$self->{+QUEUE} // []}) {
        my $rstate = $self->{+RUN_STATES}->{$run_id};
        $run_data = $rstate ? $rstate->TO_JSON : {run_id => $run_id};
    }
    elsif (my $info = $self->{+COMPLETED_RUNS}->{$run_id}) {
        # Completed snapshot is not a Run-shaped TO_JSON; wrap it so
        # consumers still see the same {type,item,run_id,state} shape.
        $run_data = {
            run_id  => $run_id,
            state   => 'complete',
            results => $info->{results} // {},
            done    => $info->{done}    // [],
            pass    => $info->{pass},
        };
    }
    else {
        return;
    }

    $self->_send_to_subscriber(
        $peer => {
            type   => 'state',
            item   => 'run',
            run_id => $run_id,
            state  => $run_data,
        },
    );
}

# Deliver one message to a subscriber. Uses the service's own
# client to piggy-back on IPC::Manager's internal peer cache
# instead of constructing a new Handle per-peer (Handles are only
# needed when the sender is doing a sync_request and needs to wait
# for a response; a plain send_message() goes through the client
# directly and accepts any named peer on the bus, including
# clients that are not themselves services).
#
# On a send failure we ask the bus whether the peer is still
# registered. If peer_exists() says yes, the failure is transient
# (bus congestion, a racing suspend, etc.) and we queue a retry
# for the next tick. If peer_exists() says no, the peer is gone
# for good; skip the retry and unsubscribe now so we stop sending
# them anything else.
sub _send_to_subscriber {
    my ($self, $peer, $payload) = @_;

    my $ok  = eval { $self->client->send_message($peer, $payload); 1 };
    my $err = $@;

    return if $ok;

    my $peer_alive = eval { $self->client->peer_exists($peer) };
    unless ($peer_alive) {
        warn "Test2::Harness2: subscriber '$peer' is gone, unsubscribing: $err\n";
        delete $self->{+SUBSCRIBERS}->{$peer};
        delete $self->{+SUBSCRIBER_RETRY}->{$peer};
        return;
    }

    my $retry = $self->{+SUBSCRIBER_RETRY}->{$peer} //= {};
    $retry->{pending} //= [];
    push @{$retry->{pending}} => $payload;

    # Cap per-peer retry queue. A subscriber that never drains will
    # otherwise balloon harness memory. When the cap is hit, drop the
    # oldest payloads (FIFO) and warn once -- the consumer is broken
    # in some way and there is no good way to recover the lost
    # messages, but the harness must stay healthy.
    my $cap = SUBSCRIBER_RETRY_CAP;
    if (@{$retry->{pending}} > $cap) {
        my $excess = @{$retry->{pending}} - $cap;
        splice @{$retry->{pending}}, 0, $excess;
        unless ($retry->{capped_warned}++) {
            warn "Test2::Harness2: subscriber '$peer' retry queue exceeded "
               . "$cap; dropping oldest payloads.\n";
        }
    }
    return;
}

# Called once per service tick to drain retries. Per-payload the
# same peer_alive gate applies: a send failure is retried while
# the peer is still on the bus, and dropped (with the peer
# unsubscribed) once peer_exists() reports it gone.
sub _drain_subscriber_retries {
    my $self = shift;

    my $retries = $self->{+SUBSCRIBER_RETRY};
    return unless keys %$retries;

    for my $peer (keys %$retries) {
        my $entry = $retries->{$peer};
        my @queue = @{$entry->{pending} // []};
        $entry->{pending} = [];

        my $peer_gone = 0;
        for my $i (0 .. $#queue) {
            my $payload = $queue[$i];
            my $ok      = eval { $self->client->send_message($peer, $payload); 1 };
            my $err     = $@;

            next if $ok;

            my $peer_alive = eval { $self->client->peer_exists($peer) };
            unless ($peer_alive) {
                warn "Test2::Harness2: subscriber '$peer' is gone, unsubscribing: $err\n";
                $peer_gone = 1;
                last;
            }

            # Peer is still on the bus but the send failed again.
            # Keep this payload (and anything after it we have not
            # sent yet) for the next tick so we do not reorder the
            # stream or drop messages just because the bus is
            # momentarily backed up.
            push @{$entry->{pending}} => @queue[$i .. $#queue];
            last;
        }

        if ($peer_gone) {
            delete $self->{+SUBSCRIBERS}->{$peer};
            delete $self->{+SUBSCRIBER_RETRY}->{$peer};
        }
        elsif (!@{$entry->{pending}}) {
            delete $self->{+SUBSCRIBER_RETRY}->{$peer};
        }
    }

    return;
}

sub request_handler_detach {
    my ($self, $payload) = @_;
    my $pid = $payload->{pid};
    return {ok => 0, error => "missing 'pid'"} unless defined $pid;

    $self->{+WATCH_PIDS} = [grep { $_ != $pid } @{$self->{+WATCH_PIDS}}];
    return {ok => 1};
}

# Run-service aggregation: replace our mirror Run::State's pending /
# running / done lists (and results map) with the run service's
# authoritative snapshot. When that replacement closes the run out
# (nothing pending, nothing running), tear down the run service and
# emit run_ended.
#
# run_data is the full Run::State->TO_JSON payload; the harness's
# shadow State picks up the lifecycle slots while the immutable Run
# spec stays untouched.
sub _handle_run_state_update {
    my ($self, $content) = @_;
    return unless ref($content) eq 'HASH';

    my $run_id = $content->{run_id};
    my $data   = $content->{run_data};
    return unless defined $run_id && ref($data) eq 'HASH';

    my ($run) = grep { $_->run_id eq $run_id } @{$self->{+QUEUE} // []};
    return unless $run;

    my $rstate = $self->{+RUN_STATES}->{$run_id} //= Test2::Harness2::Run::State->new(run_id => $run_id);

    for my $slot (qw/pending running done/) {
        my $list = $data->{$slot};
        next unless ref($list) eq 'ARRAY';
        $rstate->{$slot} = [@$list];
    }

    if (ref($data->{results}) eq 'HASH') {
        $rstate->{results} = {%{$data->{results}}};
    }

    for my $field (
        qw/created_at start_time finish_time completed exit_summary aborted_reason
        running_harness_uuid collector_uuid bus_address running_session_uuid/
        )
    {
        $rstate->{$field} = $data->{$field} if exists $data->{$field};
    }

    # Notify state subscribers with the full authoritative snapshot
    # we just received. Fan-out happens before finalization so a
    # subscriber that just came online sees the terminal state via
    # the update path, and also via any retained COMPLETED_RUNS entry
    # after finalize runs.
    $self->_notify_state_subscribers($run_id, $data);

    # Finalization is scheduler-driven: only consider the run done
    # when the scheduler has both no pending jobs and no running
    # jobs of its own. The State mirror's is_complete is informational.
    $self->_finalize_run_if_complete($run);

    return;
}

# Build the "final" snapshot stashed into COMPLETED_RUNS so that
# callers can query pass/fail via IPC after a run ends but before
# the harness itself exits. Aggregate pass is true when every job
# that reported a result passed; skipped jobs have no result entry
# and therefore do not fail the aggregate.
sub _snapshot_run_results {
    my ($self, $run) = @_;

    my $rstate   = $self->{+RUN_STATES}->{$run->run_id};
    my $results  = ($rstate && $rstate->results) // {};
    my $all_pass = 1;
    for my $jid (keys %$results) {
        # Entries without completed_at are queue-time or started-time
        # seeds (jobs that never finished or were skipped). Only
        # completed jobs contribute to the aggregate verdict.
        next          unless defined $results->{$jid}{completed_at};
        $all_pass = 0 unless $results->{$jid}{pass};
    }

    return {
        run_id  => $run->run_id,
        state   => 'complete',
        pass    => $all_pass ? 1 : 0,
        results => {%$results},
        done    => $rstate ? [@{$rstate->done}] : [],
    };
}

# Run-service aggregation: per-job release. Looks up the job's
# tracking entry for its assigned resources, releases them, drops
# the entry, and tells the scheduler the job is done. The Run
# mirror's done list is filled in independently from
# run_state_update broadcasts.
sub _handle_job_release {
    my ($self, $content) = @_;
    return unless ref($content) eq 'HASH';

    my $job_id = $content->{job_id};
    return unless defined $job_id;

    my $cur = delete $self->{+RUNNING_JOBS}->{$job_id};
    return unless $cur;

    my $run_id = $cur->{run}->run_id;
    $self->_forget_run_pid($run_id, $cur->{pid}) if $cur->{pid};
    $self->_scheduler_mark_done($run_id, $job_id);
    $self->_release_job_resources($cur);

    # The job that just finished may have been the last one for
    # its run; check from the scheduler's own perspective.
    $self->_finalize_run_if_complete($cur->{run});
    return;
}

sub _release_job_resources {
    my ($self, $cur) = @_;

    my $assigned = $cur->{assigned_resources} or return;
    my $id       = $cur->{assign_id};

    for my $res (@$assigned) {
        my $ok  = eval { $res->release(id => $id, job => $cur->{job}); 1 };
        my $err = $@;
        warn "failed to release resource '" . $res->resource_name . "': $err"
            unless $ok;
    }
}

# Role::Service hooks. The shared escalator in Role::Service drives the
# loop; these methods only feed and clean up the harness-side tracking.
#
# NOTE: perform_hard_stop kills processes and clears scheduler state;
# it does NOT call teardown() on any resources. Callers that want a
# clean shutdown must invoke run_on_cleanup (or call
# _teardown_run_service explicitly for any per-run resources they
# care about) after perform_hard_stop returns.
sub service_pre_hard_stop {
    my $self = shift;
    # Drain the queue so a racing run_on_all tick cannot schedule
    # fresh work mid-shutdown.
    $self->{+QUEUE} = [];
    return;
}

sub hard_stop_pids {
    my $self = shift;

    my %pids;

    for my $cur (values %{$self->{+RUNNING_JOBS} // {}}) {
        $pids{$cur->{pid}} //= {} if $cur->{pid};
    }

    # Registered IPC::Manager workers, when present.
    if ($self->can('workers')) {
        $pids{$_} //= {} for keys %{$self->workers // {}};
    }

    for my $info (values %{$self->{+RESOURCE_SERVICES} // {}}) {
        $pids{$info->{pid}} //= {} if $info->{pid};
    }

    # Run services cascade their own TERM handlers down to per-run
    # resource services and test collectors, so signalling the run
    # service is enough to take its whole subtree down.
    for my $info (values %{$self->{+RUN_SERVICES} // {}}) {
        $pids{$info->{pid}} //= {} if $info->{pid};
    }

    return %pids;
}

sub service_post_hard_stop {
    my $self = shift;
    # Best-effort resource release for every job we were tracking.
    for my $cur (values %{$self->{+RUNNING_JOBS} // {}}) {
        $self->_release_job_resources($cur);
    }
    $self->{+RUNNING_JOBS}      = {};
    $self->{+RESOURCE_SERVICES} = {};
    $self->{+RUN_PIDS}          = {};
    $self->{+RUN_FLAGS}         = {};
    return;
}

# IPC::Manager service-loop hook: a non-worker child pid was reaped. The
# pids we track here are:
#   - running collectors (one per active job_id)
#   - resource-service processes spawned via service_* methods
# Reparented descendants (subreaper orphans) that we did not spawn also
# land here; they get no handling beyond the drain the service loop did.
#
# IPC::Manager dispatches run_on_pid serially per tick, so the restart
# branch below is not re-entered mid-invocation even though it calls back
# into the resource (which may call track_resource_service). Do not
# introduce unguarded mutation of +RESOURCE_SERVICES from another code
# path that could also execute inside a single tick.
sub run_on_pid {
    my ($self, $pid, $exit) = @_;

    # Run-service exit. The per-run supervisor finished on its own
    # (either because _teardown_run_service sent it TERM, or because
    # its parent-pid watch tripped and it exited voluntarily). Drop
    # its tracking entry and move on; any resource-service state
    # reported via IPC has already been applied.
    for my $rid (keys %{$self->{+RUN_SERVICES} // {}}) {
        my $info = $self->{+RUN_SERVICES}->{$rid};
        next unless $info->{pid} && $info->{pid} == $pid;
        delete $self->{+RUN_SERVICES}->{$rid};
        $self->_forget_run_pid($rid, $pid);
        return;
    }

    # Test-collector exit. The harness owns the collector now (Stage 5
    # of the RunService flatten), so this is the normal reap site.
    # The auditor's test_job_completed message may have already
    # arrived before the pid was reaped, in which case nothing more
    # is needed beyond clearing the per-run pid index. If it has
    # not, arm a grace timer so the watchdog in run_on_interval can
    # synthesize completion if the auditor never gets a chance to
    # speak (collector crash, signal during emit, etc.).
    for my $job_id (keys %{$self->{+RUNNING_JOBS} // {}}) {
        my $cur = $self->{+RUNNING_JOBS}->{$job_id};
        next unless $cur->{pid} && $cur->{pid} == $pid;

        my $run    = $cur->{run};
        my $run_id = $run->run_id;
        my $flags  = $self->{+RUN_FLAGS}->{$run_id};

        # Already completed (test_job_completed landed before the
        # reap): forget the per-run pid index entry; let job_release
        # handle the RUNNING_JOBS / resource-release cleanup as
        # usual.
        if ($flags && $flags->{completed_job_ids}{$job_id}) {
            $self->_forget_run_pid($run_id, $pid);
            return;
        }

        # Not completed yet: arm a synth-completion grace entry.
        # KEEP RUNNING_JOBS in place; a real test_job_completed
        # arriving inside the grace window cancels the synth, and
        # the watchdog reuses the existing RUNNING_JOBS entry to
        # synthesize a completion + cleanup if the window expires.
        $self->{+PENDING_SYNTH_COMPLETIONS}->{$job_id} = {
            run_id           => $run_id,
            job_id           => $job_id,
            job_try          => $cur->{job} ? $cur->{job}->job_try : undef,
            pid              => $pid,
            pid_gone_at      => time,
            raw_exit_on_reap => $exit,
        };

        return;
    }

    # Resource-service exit (handled by the shared host role, which
    # takes care of restart-spiral protection, state flags, and
    # re-invocation). Reparented descendants that aren't one of ours
    # silently fall through.
    $self->handle_resource_service_exit($pid, $exit);

    return;
}

# Collector-side watchdog: if a collector pid disappeared without
# test_job_completed being received, synthesize completion once the
# grace window expires. IPC::Manager drives run_on_interval roughly
# every 0.2s so the resolution is sub-second even though the grace
# window is seconds-scale.
sub run_on_interval {
    my $self = shift;

    my $pending = $self->{+PENDING_SYNTH_COMPLETIONS};
    return unless $pending && keys %$pending;

    my $now   = time;
    my $grace = $self->{+COLLECTOR_GRACE_SECS} // DEFAULT_COLLECTOR_GRACE_SECS;

    for my $job_id (keys %$pending) {
        my $entry  = $pending->{$job_id};
        my $run_id = $entry->{run_id};

        # A real test_job_completed arrived inside the grace window
        # -- drop the pending synth.
        my $flags = $self->{+RUN_FLAGS}->{$run_id};
        if ($flags && $flags->{completed_job_ids}{$job_id}) {
            delete $pending->{$job_id};
            next;
        }

        next if ($now - $entry->{pid_gone_at}) < $grace;

        warn sprintf(
            "Test2::Harness2: synthesizing test_job_completed for job %s (collector pid %d): no test_job_completed in %ds after pid exit\n",
            $job_id, $entry->{pid} // 0, $grace,
        );

        delete $pending->{$job_id};

        my $raw = $entry->{raw_exit_on_reap};

        # Reuse the normal completion handler so Run::State,
        # RUN_FLAGS, run_failing latching, and the
        # collector_report aggregate all see the synthesized
        # entry. pass=0 + zero counts so the renderer surface can
        # distinguish "synthesized fail" from "real fail with
        # known counts".
        $self->_handle_test_job_completed({
            run_id     => $run_id,
            job_id     => $job_id,
            job_try    => $entry->{job_try},
            exit       => $raw,
            pass       => 0,
            pass_count => 0,
            fail_count => 0,
            stamp      => time,
            synth      => 1,
        });

        # The collector died without sending job_release, so the
        # release / scheduler cleanup that _handle_job_release
        # normally does has to fire here too.
        $self->_synth_release_orphan_job($run_id, $job_id, $entry->{pid});
    }

    return;
}

# Counterpart to _handle_job_release for the watchdog path: when
# the auditor never got a chance to send job_release, the harness
# has to release the resources, drop the RUNNING_JOBS entry, mark
# the scheduler done, and trigger run-finalization itself.
sub _synth_release_orphan_job {
    my ($self, $run_id, $job_id, $pid) = @_;

    my $cur = delete $self->{+RUNNING_JOBS}->{$job_id};
    return unless $cur;

    $self->_forget_run_pid($run_id, $pid) if $pid;
    $self->_release_job_resources($cur);
    $self->_scheduler_mark_done($run_id, $job_id);
    $self->_finalize_run_if_complete($cur->{run}) if $cur->{run};
    return;
}

sub run_should_end {
    my $self = shift;

    my $has_running = keys %{$self->{+RUNNING_JOBS} // {}} ? 1 : 0;

    if ($self->{+STATE} eq 'terminating') {
        return 1 unless $has_running;
        return 0;
    }

    if ($self->{+STATE} eq 'finishing') {
        return 1 if !$has_running && !@{$self->{+QUEUE}};
        return 0;
    }

    return 0;
}

# Role::Service provides run_on_start. It handles setpgid,
# subreaper registration, and the service_started emit uniformly;
# we only supply the harness-specific startup step.
sub service_on_start {
    my $self = shift;
    $self->start_resource_services($self->{+RESOURCES}, scope => 'global');
    return;
}

sub run_on_cleanup {
    my $self = shift;

    # Snapshot the queue so we can tear down per-run resources for any
    # runs that didn't complete cleanly -- perform_hard_stop drains the
    # queue before returning.
    my @leftover_runs = @{$self->{+QUEUE} // []};

    my $has_running = keys %{$self->{+RUNNING_JOBS} // {}};
    $self->perform_hard_stop if $has_running || @{$self->{+QUEUE}};

    $self->_teardown_run_service($_) for @leftover_runs;

    # Guard every teardown so a throwing resource cannot short-circuit the
    # loop and skip the service_stopped emit that downstream callers rely
    # on to observe a clean shutdown.
    for my $res (@{$self->{+RESOURCES} // []}) {
        my $ok  = eval { $res->teardown; 1 };
        my $err = $@;
        warn "resource '" . $res->resource_name . "' teardown died: $err"
            unless $ok;
    }

    $self->emit_service_event(kind => 'service_stopped');
}

sub emit_service_event {
    my ($self, %fields) = @_;
    my $em = $self->{+EMITTER} or return;    # no emitter in tests
    $em->emit_event(%fields);
}

sub TO_JSON {
    my $self = shift;
    return {
        name    => $self->{+NAME},
        job_id  => $self->{+JOB_ID},
        workdir => $self->{+WORKDIR},
        pid     => $self->pid,
    };
}

# Scheduler state. The harness keeps its own pending/running view
# of every queued run, populated once at queue time from the run's
# initial job list and mutated only by the harness's own scheduling
# decisions (launch, skip, completion). It deliberately never
# reads or writes the Run object's pending/running/done arrays
# (those mirror what the run service broadcasts back, which the
# scheduler should not depend on -- the broadcasts can race and
# would otherwise resurrect already-launched jobs into the
# pending list).
sub _scheduler_queue_run {
    my ($self, $run) = @_;
    my $rid = $run->run_id;
    $self->{+SCHEDULER}->{$rid} = {
        pending => [map { $_->job_id } @{$run->jobs}],
        running => {},
        started => 0,
    };
    return;
}

sub _scheduler_pending_for_run {
    my ($self, $run_id) = @_;
    my $s = $self->{+SCHEDULER}->{$run_id} or return [];
    return $s->{pending};
}

sub _scheduler_is_running {
    my ($self, $run_id, $job_id) = @_;
    my $s = $self->{+SCHEDULER}->{$run_id} or return 0;
    return $s->{running}->{$job_id} ? 1 : 0;
}

sub _scheduler_started {
    my ($self, $run_id) = @_;
    my $s = $self->{+SCHEDULER}->{$run_id} or return 0;
    return $s->{started};
}

sub _scheduler_mark_running {
    my ($self, $run_id, $job_id) = @_;
    my $s = $self->{+SCHEDULER}->{$run_id} or return;
    $s->{pending}            = [grep { $_ ne $job_id } @{$s->{pending}}];
    $s->{running}->{$job_id} = 1;
    $s->{started}            = 1;
    return;
}

sub _scheduler_mark_done {
    my ($self, $run_id, $job_id) = @_;
    my $s = $self->{+SCHEDULER}->{$run_id} or return;
    delete $s->{running}->{$job_id};
    return;
}

sub _scheduler_skip {
    my ($self, $run_id, $job_id) = @_;
    my $s = $self->{+SCHEDULER}->{$run_id} or return;
    $s->{pending} = [grep { $_ ne $job_id } @{$s->{pending}}];
    $s->{started} = 1;
    return;
}

sub _scheduler_drop_run {
    my ($self, $run_id) = @_;
    delete $self->{+SCHEDULER}->{$run_id};
    return;
}

sub _scheduler_run_complete {
    my ($self, $run_id) = @_;
    my $s = $self->{+SCHEDULER}->{$run_id};
    return 1 unless $s;    # already dropped
    return 0 if @{$s->{pending}};
    return 0 if keys %{$s->{running}};

    # The scheduler has nothing left of its own to do for the run,
    # but the run is only really finished once we have also seen
    # the started flag flip -- otherwise an empty queue at startup
    # would look "complete" to us before we ever launched anything.
    return $s->{started} ? 1 : 0;
}

sub run_on_all {
    my ($self, $activity) = @_;

    # Job completion flows through the run service: test collectors
    # emit test_job_completed to the run service, which aggregates
    # and sends us job_release (for resource release + wake) plus
    # run_state_update (to mirror the Run). The run service's own
    # watchdog synthesizes completion on collector death. Nothing
    # here beyond driving the scheduler forward.
    return if $self->{+STATE} eq 'terminating';

    # Launch as many pending jobs as the active resources permit this tick.
    1 while $self->_try_launch_next_pending;
}

sub _try_launch_next_pending {
    my $self = shift;

    return 0 unless @{$self->{+QUEUE} // []};

    # Runs are processed serially in the order they were queued.
    # The scheduler iterates QUEUE (an ordered arrayref) and finds
    # the first run that is not yet complete from the scheduler's
    # perspective; that becomes the head run for this tick. Other
    # queued runs are not even considered until the head run has
    # drained its own pending+running. We never run a later run
    # ahead of an earlier one.
    my $head_run;
    for my $run (@{$self->{+QUEUE}}) {
        next if $self->_scheduler_run_complete($run->run_id);
        $head_run = $run;
        last;
    }
    return 0 unless $head_run;

    my $run_id = $head_run->run_id;

    # Lazy per-run resource startup: the first time this run is
    # considered for launch we spin up its resource services.
    $self->_ensure_run_service_started($head_run);

    # Iterate the scheduler's own pending list, not $run->pending.
    # The scheduler's list is the authoritative view of what we
    # have not yet attempted to launch; $run->pending mirrors
    # the run service and can lag behind reality.
    for my $job_id (@{$self->_scheduler_pending_for_run($run_id)}) {
        my ($job) = grep { $_->job_id eq $job_id } @{$head_run->jobs};
        next unless $job;

        # Run-level abort state (see _handle_broken_resource):
        # once a run is aborted, every remaining job takes the
        # unavailable-action fail path, whether or not that specific
        # job needed the broken resource. The aborted flag on the
        # decision distinguishes the original trigger (aborted=0)
        # from follow-ups swept up by the abort (aborted=1).
        my ($decision, $arg, %dec_opts);
        my $rstate = $self->{+RUN_STATES}->{$head_run->run_id};
        if ($rstate && defined $rstate->aborted_reason) {
            ($decision, $arg) = ('broken', $rstate->aborted_reason);
            $dec_opts{aborted} = 1;
        }
        else {
            ($decision, $arg) = $self->_evaluate_resources_for($head_run, $job);
        }

        if ($decision eq 'skip') {
            # A resource is healthy but can never grant the slots THIS
            # job demands (e.g. test declares HARNESS-JOB-SLOTS 8 and
            # the per-job cap is 4). Route through the unavailable-action
            # skip launch so the renderer/log show a real skip_all event
            # with a reason, the run service sees a normal job
            # completion, and the run can finalize. The skip launch
            # itself goes through the limiter pool with need=1, so it
            # may defer if the pool is currently saturated.
            my $outcome = $self->_launch_unavailable_action_job($head_run, $job, 'skip', $arg);
            return 1 if $outcome eq 'launched' || $outcome eq 'skip';
            next;    # 'defer' -- try again next tick
        }

        if ($decision eq 'broken') {
            # A needed resource has been permanently broken (or
            # the run has been aborted wholesale).
            # broken_resource_behavior decides how the job is
            # dispatched; the unavailable-action launch shares the
            # job-limiter pool and may defer if the pool is saturated.
            my $outcome = $self->_handle_broken_resource($head_run, $job, $arg, %dec_opts);
            return 1 if $outcome eq 'launched' || $outcome eq 'skip';
            next;    # 'defer' -- try the next job in this run
        }

        next if $decision eq 'defer';

        $self->_launch_job($head_run, $job, $arg);
        return 1;
    }

    return 0;
}

# Finalize the run if it's complete: snapshot final results from
# the Run mirror, drop the run from the queue, tear down its per-
# run service, and transition the harness to finishing if we're
# in finish_after_initial_run mode.
#
# Finalization is gated by the Run mirror's is_complete: that is
# the run service's authoritative "all jobs done, here are the
# final results" signal. The scheduler's own pending+running
# view is for launch decisions, not finalization -- it can reach
# empty before the mirror has the results we need to snapshot.
sub _finalize_run_if_complete {
    my ($self, $run) = @_;
    my $run_id = $run->run_id;

    my $rstate = $self->{+RUN_STATES}->{$run_id};
    return unless $rstate && $rstate->is_complete;

    # Idempotent: if we already finalized this run, do nothing.
    return if $self->{+COMPLETED_RUNS}->{$run_id};

    $self->{+COMPLETED_RUNS}->{$run_id} = $self->_snapshot_run_results($run);

    # Emit the terminal run_completed + collector_report event from
    # the harness BEFORE the per-run state is dropped. This used to
    # live in RunService.emit_run_completed; the harness owns Run
    # state now so it owns the aggregate.
    $self->_emit_run_completed($run);

    $self->{+QUEUE} = [grep { $_->run_id ne $run_id } @{$self->{+QUEUE}}];
    delete $self->{+RUN_STATES}->{$run_id};
    delete $self->{+RUN_FLAGS}->{$run_id};
    $self->_scheduler_drop_run($run_id);
    $self->_teardown_run_service($run);
    $self->emit_service_event(
        kind     => 'run_ended',
        run_data => {run_id => $run_id},
    );
    $self->{+STATE} = 'finishing'
        if $self->{+FINISH_AFTER_INITIAL_RUN}
        && $self->{+STATE} eq 'running';

    return;
}

# Dispatch for ($decision eq 'broken'): a needed resource is
# permanently broken. Which of skip / fail / abort to do is governed
# by the harness-level broken_resource_behavior attribute.
#
# All three paths route the job through a real Collector launch --
# skip runs a one-liner that calls skip_all, fail runs a one-liner
# that dies, abort is per-job fail for the whole remaining run.
# That way the auditor and on-disk artifacts are produced the same
# way they would be for a real test; no job is ever silently dropped.
#
# Returns 'launched', 'defer' (limiter full), or 'skip' (the
# unavailable-action launch is impossible: e.g. no job-limiter is
# usable any more).
sub _handle_broken_resource {
    my ($self, $run, $job, $resource_name, %opts) = @_;

    my $behavior = $self->{+BROKEN_RESOURCE_BEHAVIOR};
    my $aborted  = $opts{aborted} ? 1 : 0;

    if ($behavior eq 'skip') {
        return $self->_launch_unavailable_action_job(
            $run, $job, 'skip', $resource_name, aborted => $aborted,
        );
    }

    if ($behavior eq 'fail') {
        return $self->_launch_unavailable_action_job(
            $run, $job, 'fail', $resource_name, aborted => $aborted,
        );
    }

    # abort: record the reason on the run state so every other
    # pending job also takes the fail path (see
    # _try_launch_next_pending), then synthesize fail for THIS job.
    # The scheduler drives the rest one at a time as the job limiter
    # frees slots -- we never try to launch N synth-fail jobs against
    # a single-slot limiter at once. The current job is the trigger;
    # follow-ups arrive through the scheduler's aborted-run branch
    # with aborted => 1 already set on their dec_opts.
    if (my $rstate = $self->{+RUN_STATES}->{$run->run_id}) {
        $rstate->latch_aborted_reason($resource_name);
    }
    return $self->_launch_unavailable_action_job(
        $run, $job, 'fail', $resource_name, aborted => $aborted,
    );
}

# Launch an unavailable-action skip/fail via the normal Collector
# path, using a perl -e one-liner instead of the real test file. Only
# job_limiter resources that are NOT permanent_broken get consulted
# (with a fixed need=1) -- the broken resource itself is of course
# skipped, and non-limiter resources don't participate in accounting
# for one-off unavailable-action runs.
#
# Returns 'launched', 'defer' (limiter full right now), or 'skip' (no
# usable limiter at all, so the unavailable-action launch can never
# run).
sub _launch_unavailable_action_job {
    my ($self, $run, $job, $unavailable_action, $resource_name, %opts) = @_;

    croak "unavailable_action kind must be 'skip' or 'fail' (got '$unavailable_action')"
        unless $unavailable_action eq 'skip' || $unavailable_action eq 'fail';

    my $aborted = $opts{aborted} ? 1 : 0;
    my $reason =
        $aborted
        ? "Run aborted: missing resources: $resource_name"
        : "Missing resources: $resource_name";

    # perl -Ilib -e ... -- <reason>. ARGV carries the reason so we
    # don't have to quote the message into the -e body. -Ilib mirrors
    # the real-test launch in the RunService so Test2::Formatter::Stream2
    # (and any other @INC-dependent harness plumbing) resolves the
    # same way it does under a real test.
    my $script =
        $unavailable_action eq 'skip'
        ? 'use Test2::V0; skip_all($ARGV[0])'
        : 'die "$ARGV[0]\n"';
    my $launch = [$^X, '-Ilib', '-e', $script, '--', $reason];

    # Pull every resource the scheduler would have consulted for this
    # synthetic job: anything the resource itself reports as
    # `needed(job => $job)` and that has not been permanent-broken.
    # The `is_job_limiter` filter is gone; resources that genuinely
    # have no slot footprint for a synthetic skip/fail (e.g. a GPU
    # gating resource) are expected to opt themselves out via
    # `needed`.
    my @all = (@{$self->{+RESOURCES}}, @{$run->resources // []});
    my @limiters =
        grep { !$_->is_permanent_broken && $_->needed(job => $job) } @all;

    # Availability gate: share the run's job-limiter pool with real
    # tests. If every usable limiter is saturated right now, defer
    # and let the scheduler re-try on the next tick once a slot frees.
    # If a limiter can never accommodate us (-1, which should not
    # happen with need=1 on a single-slot pool but is possible in
    # pathological configurations) the unavailable-action job is
    # skipped outright.
    for my $res (@limiters) {
        my $av = $res->available(job => $job, min => 1, max => 1, need => 1);
        if ($av < 0) {
            $self->_scheduler_skip($run->run_id, $job->job_id);
            $self->_finalize_run_if_complete($run);
            return 'skip';
        }
        return 'defer' if $av == 0;
    }

    $self->_launch_job(
        $run, $job, \@limiters,
        launch      => $launch,
        assign_args => {min => 1, max => 1, need => 1},
    );

    return 'launched';
}

sub _evaluate_resources_for {
    my ($self, $run, $job) = @_;

    # Global resources are consulted first, then per-run resources
    # layered on top. Either set may defer, skip, or report a broken
    # resource; all-or-nothing commitment is preserved because we
    # only call assign() in _launch_job after the entire walk returns
    # ('launch', \@use).
    #
    # Return shape: ('launch', \@use)
    #               ('defer')
    #               ('skip', $resource_name)
    #                          - resource is present but can never
    #                            grant THIS specific job (e.g. job's
    #                            min_slots exceeds the resource's
    #                            per-job cap). Scheduler routes the
    #                            job through the unavailable-action
    #                            skip launch so the user sees a real
    #                            skip_all event and the run still
    #                            completes; other jobs that fit the
    #                            cap continue to use the resource.
    #               ('broken', $resource_name)
    #                          - a needed resource has been flipped
    #                            to permanent_broken. Scheduler
    #                            consults broken_resource_behavior
    #                            to decide skip / fail / abort.
    my @all = (@{$self->{+RESOURCES}}, @{$run->resources // []});

    my @use;
    for my $res (@all) {
        next unless $res->needed(job => $job);

        return ('broken', $res->resource_name) if $res->is_permanent_broken;

        # Transient brokenness / paused state: try again later.
        return ('defer') unless $res->is_usable;

        my $av = $res->available(job => $job);
        return ('skip', $res->resource_name) if $av < 0;
        return ('defer')                     if !$av;

        push @use => $res;
    }

    return ('launch', \@use);
}

sub _ensure_run_service_started {
    my ($self, $run) = @_;

    # The resources_started / resources_torn_down idempotency flags
    # live on the paired Run::State (post-queue mutable state, not on
    # the immutable spec).
    my $rstate = $self->{+RUN_STATES}->{$run->run_id} //=
        Test2::Harness2::Run::State->new(run_id => $run->run_id);
    return if $rstate->resources_started_flag;
    $rstate->mark_resources_started;

    # In unit tests that exercise scheduler logic without building a
    # real IPC bus, ipcm_info is undef; skip the fork then so the
    # rest of the scheduler still works. Production code paths
    # (start/spawn) always set ipcm_info before this method runs.
    return unless defined $self->ipcm_info;

    my $run_id = $run->run_id;
    my $bus    = "run-$run_id";

    my $pid = Test2::Harness2::RunService->spawn(
        workdir      => $self->{+WORKDIR},
        logdir       => $self->{+LOGDIR},
        run          => $run,
        ipcm_info    => $self->ipcm_info,
        parent_pids  => [$$],
        harness_name => $self->{+NAME},
        kill_timeout => $self->{+KILL_TIMEOUT},
    );

    my $started_at = time;
    $self->{+RUN_SERVICES}->{$run_id} = {
        pid        => $pid,
        run        => $run,
        bus_name   => $bus,
        started_at => $started_at,
    };
    $self->_register_run_pid(
        $run_id, $pid,
        kind       => 'run_service',
        bus_name   => $bus,
        started_at => $started_at,
    );

    # Bring up the run's resource services. They run as direct
    # children of the harness (not the run service), so signal/kill
    # propagation is uniform with the global resources hosted here
    # already, and the per-run pid bookkeeping in RUN_PIDS captures
    # them via the host-role tracking hooks. The harness has already
    # validated the resource set (needed + non-permanent) before
    # taking this branch -- we just start whatever is configured.
    my $resources = $run->resources // [];
    if (@$resources) {
        my $rs_ok = eval {
            $self->start_resource_services($resources, scope => 'run', run => $run);
            1;
        };
        unless ($rs_ok) {
            my $err = $@;
            warn "Test2::Harness2: per-run resource services for '$run_id' failed to start: $err\n";
        }
    }

    return;
}

# Lazy-build an IPC handle to the run service, once we need to make a
# sync_request into it. Cached on the run-services entry so repeated
# launches reuse one handle.
sub _run_service_handle {
    my ($self, $run_id) = @_;

    my $entry = $self->{+RUN_SERVICES}->{$run_id}
        or croak "no run service tracked for run '$run_id'";

    return $entry->{_handle} //= IPC::Manager::Service::Handle->new(
        service_name => $entry->{bus_name},
        ipcm_info    => $self->ipcm_info,
    );
}

# Block briefly waiting for a newly-spawned run service to be ready
# to accept IPC requests. sync_request itself queues messages that
# arrive before the service is up, but the timeout behaviour is
# clearer if we wait explicitly.
#
# The original hardcoded 10s cap assumed Linux-container scheduling
# where IPC sockets bind essentially instantly. That assumption
# breaks on macOS and intermittently on slower CI containers -- see
# issue #392. Default raised to 60s and made env-overridable via
# YATH_RUN_SERVICE_READY_TIMEOUT so contributors on slower hosts
# can tune without a source patch.
sub _wait_for_run_service_ready {
    my ($self, $run_id) = @_;

    my $handle   = $self->_run_service_handle($run_id);
    my $cap      = $ENV{YATH_RUN_SERVICE_READY_TIMEOUT} // 60;
    my $deadline = time + $cap;
    until ($handle->ready) {
        croak "timeout waiting for run service '$run_id' to come up after ${cap}s"
            if time > $deadline;
        tinysleep(0.02);
    }
    return $handle;
}

sub _teardown_run_service {
    my ($self, $run) = @_;

    # Called from three sites: _handle_run_state_update (normal run
    # completion observed via the run service's aggregated snapshot),
    # _try_launch_next_pending (all-skipped completion), and
    # run_on_cleanup (runs left in the queue at shutdown). The
    # resources_torn_down flag below makes each call idempotent. The
    # flag lives on the paired Run::State because it reflects runtime
    # state, not the queue-time spec.
    my $rid    = $run->run_id;
    my $rstate = $self->{+RUN_STATES}->{$rid};
    return                            if $rstate && $rstate->resources_torn_down_flag;
    $rstate->mark_resources_torn_down if $rstate;
    my $svc = delete $self->{+RUN_SERVICES}->{$rid};
    # Tear down the run's resource services -- they live under the
    # harness now (Stage 3 of the RunService flatten), so we own the
    # signal cascade. _kill_run targets only this run's RUN_PIDS
    # entries; resource services flagged kind='resource_service' under
    # this run_id get TERM, the role's restart-spiral counter is
    # reset implicitly because the service is no longer tracked once
    # it exits via run_on_pid, and per-resource teardown methods run
    # on the resource objects themselves so any in-process cleanup
    # (counters, files, etc.) still fires here.
    for my $res (@{$run->resources // []}) {
        my $tok  = eval { $res->teardown; 1 };
        my $terr = $@;
        warn "resource '" . $res->resource_name . "' teardown died: $terr"
            unless $tok;
    }
    $self->_kill_run($rid, 'TERM');

    return unless $svc;
    return unless $svc->{pid};

    # SIGTERM the run service. Its SIG{TERM} handler flips the service
    # state to 'terminating' and run_on_cleanup inside the child will
    # cascade TERMs to its remaining tracked children (collectors)
    # before exiting. The reap lands on our side via IPC::Manager's
    # waitpid tick and falls through run_on_pid -- see the
    # run-services guard there.
    kill TERM => $svc->{pid} if kill 0 => $svc->{pid};

    return;
}

sub _launch_job {
    my ($self, $run, $job, $resources, %opts) = @_;

    my $run_id = $run->run_id;
    my $job_id = $job->job_id;

    # First job of this run -- announce run_started and stamp the
    # per-run started_at slot so the eventual run_completed +
    # collector_report event can carry wall-time bracketing.
    unless ($self->_scheduler_started($run_id)) {
        $self->emit_service_event(
            kind     => 'run_started',
            run_data => {run_id => $run_id},
        );
        my $flags = $self->_run_flags($run_id);
        $flags->{started_at} //= time;
    }

    my $assign_id = gen_uuid();
    my %env;
    # Forward T2_HARNESS_INCLUDES from the parent environment to the
    # spawned test child so callers can inject paths into the child's
    # @INC without resorting to per-test CLI flags. Mirrors
    # reference/old2/lib/Test2/Harness2/TestSettings.pm:122.
    $env{T2_HARNESS_INCLUDES} = $ENV{T2_HARNESS_INCLUDES}
        if defined $ENV{T2_HARNESS_INCLUDES} && length $ENV{T2_HARNESS_INCLUDES};

    # --set-hash-seed propagation: Phase 7.1. The run carries the
    # effective seed value (resolved from the option's autofill or
    # the user-supplied value at queue-build time). When set, every
    # test child gets PERL_HASH_SEED so the child interpreter starts
    # with a deterministic hash seed. When the run does not request
    # one, the child inherits whatever the parent's PERL_HASH_SEED
    # already is (which the App-Yath-Script wrapper or the user may
    # or may not have set).
    my $hash_seed = $run->hash_seed;
    $env{PERL_HASH_SEED} = $hash_seed if defined $hash_seed && length $hash_seed;
    my %assign_args = %{$opts{assign_args} // {}};
    for my $res (@$resources) {
        $res->assign(id => $assign_id, job => $job, env => \%env, %assign_args);
    }

    # Spawn the Collector directly. Stage 5 of the RunService flatten:
    # the harness owns the collector fork, the test process is its
    # grandchild, and the run service is no longer in the test-launch
    # path. Reap lands at run_on_pid; auditor sends straight back here.
    my $launch_ok = eval {
        my $resp = $self->_spawn_collector_for_job(
            $run, $job,
            env     => \%env,
            (defined $opts{launch} ? (launch => $opts{launch}) : ()),
        );
        die "collector spawn returned no pid"
            unless ref($resp) eq 'HASH' && $resp->{ok} && $resp->{pid};

        $self->_scheduler_mark_running($run_id, $job_id);

        my $started_at = time;
        $self->{+RUNNING_JOBS}->{$job_id} = {
            run                => $run,
            job                => $job,
            pid                => $resp->{pid},
            started_at         => $started_at,
            assign_id          => $assign_id,
            assigned_resources => $resources,
            log_file           => $resp->{log_file},
        };
        $self->_register_run_pid(
            $run_id, $resp->{pid},
            kind       => 'collector',
            job_id     => $job_id,
            job_try    => $job->job_try,
            started_at => $started_at,
        );

        1;
    };
    my $launch_err = $@;

    unless ($launch_ok) {
        # Launch failed; release the resources we just committed so
        # their slots don't leak. The job never reached RUNNING_JOBS
        # so _release_job_resources won't reach it on its own.
        for my $res (@$resources) {
            my $rok  = eval { $res->release(id => $assign_id, job => $job); 1 };
            my $rerr = $@;
            warn "failed to release resource '" . $res->resource_name . "' after launch failure: $rerr"
                unless $rok;
        }
        die $launch_err;
    }

    return $job_id;
}

# Build the Collector spawn args + invoke Collector->spawn directly,
# without going through the RunService IPC. Inlined from the body of
# RunService::request_handler_launch_job. Returns the same shape:
# {ok => 1, pid => $collector_pid, log_file => undef} or
# {ok => 0, error => "..."}.
sub _spawn_collector_for_job {
    my ($self, $run, $job, %opts) = @_;

    my $run_id  = $run->run_id;
    my $job_id  = $job->job_id;
    my $job_try = $job->job_try // 1;

    my $env     = $opts{env} // {};
    my $launch  = $opts{launch};
    my $auditor = $opts{auditor} // $self->{+TEST_AUDITOR};

    my $test_file_abs = $job->test_file_abs;
    return {ok => 0, error => "'test_file' must be absolute"}
        unless File::Spec->file_name_is_absolute($test_file_abs);

    # The unavailable-action skip / fail paths hand us an explicit
    # launch command (perl -e '...'). Default to running the real
    # test file when no override is present. Forward T2_HARNESS_INCLUDES
    # as -I flags so the child interpreter actually picks the paths up.
    if (!defined $launch) {
        my @extra_inc;
        if (my $inc = $env->{T2_HARNESS_INCLUDES}) {
            @extra_inc = grep { length && $_ ne '.' } split /;/, $inc;
        }
        $launch = [$^X, (map { "-I$_" } @extra_inc), '-Ilib', $test_file_abs];
    }

    my $test_file_spec = Test2::Harness2::TestFile->new(file => $test_file_abs);

    # queued_at on the per-job spec.jsonl artifact: pull from
    # Run::State so the renderer sees the queue-time stamp.
    my $queued_at;
    if (my $rs = $self->{+RUN_STATES}->{$run_id}) {
        my $r = $rs->results->{$job_id};
        $queued_at = $r->{queued_at} if $r && defined $r->{queued_at};
    }

    my $handle;
    my $spawn_ok = eval {
        $handle = Test2::Harness2::Collector->spawn(
            type         => 'Job',
            id           => $job_id,
            run_id       => $run_id,
            job_try      => $job_try,
            launch       => $launch,
            new_pgroup   => 1,
            parent_pids  => [$$],
            env_vars     => {T2_FORMATTER => 'Stream2', %$env},
            logdir       => $self->{+LOGDIR},
            ipcm_info    => $self->ipcm_info,
            ipc_parent   => $self->{+NAME},
            ipc_run      => $self->{+NAME},
            ipc_harness  => $self->{+NAME},
            kill_timeout => $self->{+KILL_TIMEOUT},
            spec         => {
                %{ $test_file_spec->TO_JSON },
                run_id    => $run_id,
                job_id    => $job_id,
                job_try   => $job_try,
                (defined $queued_at ? (queued_at => $queued_at) : ()),
            },
            (defined $auditor ? (auditor => $auditor) : ()),
        );
        1;
    };
    return {ok => 0, error => "collector spawn failed: $@"}
        unless $spawn_ok;

    my $pid = $handle->pid;
    return {ok => 1, pid => $pid, log_file => undef};
}

1;

__END__

=head1 NAME

Test2::Harness2 - Top-level test harness service.

=head1 SYNOPSIS

    # Run once, then exit
    Test2::Harness2->start(
        workdir                  => '/path/to/wd',
        test_run                 => {files => ['t/a.t', 't/b.t']},
        finish_after_initial_run => 1,
    );

    # Spawn as a persistent daemon, keep queuing
    my $spawn = Test2::Harness2->spawn(workdir => '/path/to/wd');
    $spawn->queue_test_run(files => ['t/c.t']);
    my $status = $spawn->status;
    $spawn->finish;
    $spawn->wait;

=head1 DESCRIPTION

B<Use start() or spawn(), not new().> Direct C<new()> constructs the object
but does not start the service loop. Prefer the C<start()> entry point when
you want the current process to become the harness, or C<spawn()> when you
want the harness to run in a child process and get back a handle to it.

=head1 JUMP_TO

Passing C<jump_to =E<gt> $name> to C<start()> tells the harness to unwind
its own call stack inside the interposed collector child before running the
service, using L<Long::Jump>. The caller must install a matching
C<setjump()> around the C<start()> call; when the longjump fires the
setjump returns a single-element arrayref whose only element is a
coderef. Invoking that coderef runs the service (set up the emitter, queue
any requested run, enter the main loop, and C<_exit>).

This is useful when a test script has deep harness machinery above the
setjump that should not be present on the service's stack. After the jump,
the service runs from a clean stack frame, so exceptions and stack traces
are tidier and an accidental C<return> out of the service cannot resume
execution anywhere unintended.

    use Long::Jump qw/setjump/;

    my $ret = setjump 'harness' => sub {
        Test2::Harness2->start(
            workdir => $wd,
            jump_to => 'harness',
            # ... other start() args ...
        );
        # unreachable in the service child; the parent becomes the
        # collector and exits without returning here either.
    };

    my ($run_service) = @$ret;
    $run_service->();   # never returns; service calls _exit

If C<jump_to> is set but no matching setjump is active, C<start()> croaks
before forking. Without C<jump_to>, C<start()> behaves exactly as before.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
