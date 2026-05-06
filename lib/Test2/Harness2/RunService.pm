package Test2::Harness2::RunService;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Path qw/make_path/;
use File::Spec;
use Scalar::Util qw/blessed/;
use Time::HiRes qw/time/;
use Test2::Util::UUID qw/gen_uuid/;
use POSIX ();

use IPC::Manager::Service::Handle;
use Test2::Harness2::Collector;
use Test2::Harness2::Role::ResourceServiceHost;
use Test2::Harness2::Role::Service;
use Test2::Harness2::Run::State;
use Test2::Harness2::TestFile;
use Test2::Harness2::Util::EventEmitter;

use Object::HashBase qw{
    <workdir
    <logdir
    <name
    <log_name
    <run_id
    <job_id
    <kill_timeout
    <ipcm_info
    <parent_pids
    <harness_name
    <collector_grace_secs
    +run
    +run_state
    state
    <resource_services
    +test_jobs
    +completed_job_ids
    +completed_job_states
    +pending_synth_completions
    +emitter
    +started_at
    +ended_at
    +run_pass
    +run_failing_emitted
    +run_completed_emitted
    watch_pids
    own_pgroup
};

# Default grace window after a collector pid goes away with no
# test_job_completed in hand. Overridable per-RunService via the
# collector_grace_secs attribute.
use constant DEFAULT_COLLECTOR_GRACE_SECS => 10;

# Public accessor for the Run object -- named run_obj rather than 'run'
# to avoid shadowing IPC::Manager::Role::Service's run() loop method.
sub run_obj   { $_[0]->{+RUN} }
sub run_state { $_[0]->{+RUN_STATE} }

# Reservation check on the role uses the log file name, not the bus
# name (which is suffixed with the run_id to guarantee uniqueness
# across runs on the shared IPC bus).
sub service_host_log_name { $_[0]->{+LOG_NAME} }

# Resource-service log files live under the harness's $logdir, not the
# bare $workdir.
sub service_host_logdir { $_[0]->{+LOGDIR} }

use Role::Tiny::With;
with 'Test2::Harness2::Role::Service', 'Test2::Harness2::Role::ResourceServiceHost';

# Role::ResourceServiceHost scope hooks: the run service is the
# run-scoped host for its Run, so its own name is reserved in per-run
# scope for this specific run. A global-scoped resource never sees this
# reservation, and other runs never collide with ours.
sub service_host_scope { 'run' }
sub service_host_run   { $_[0]->{+RUN} }

# The run service acts as a subreaper for the run's subtree (tests it
# launches and resource services scoped to this run).
sub become_sub_reaper { 1 }

sub init {
    my $self = shift;

    my $wd = $self->{+WORKDIR} // croak "'workdir' is a required attribute";
    croak "workdir '$wd' does not exist or is not a directory" unless -d $wd;

    my $run = $self->{+RUN} // croak "'run' is a required attribute";
    croak "'run' must be a Test2::Harness2::Run, got " . (blessed($run) || ref($run) || '(scalar)')
        unless blessed($run) && $run->isa('Test2::Harness2::Run');

    $self->{+RUN_ID} //= $run->run_id;

    # logdir defaults to $workdir/logs/ -- mirroring the harness's own
    # default. Callers that pass their own logdir (typically the
    # harness handing through $self->{+LOGDIR}) get that path verbatim.
    $self->{+LOGDIR} //= "$wd/logs";
    my $logdir  = $self->{+LOGDIR};
    my $svc_dir = "$logdir/runs/$self->{+RUN_ID}/services";
    make_path($svc_dir) unless -d $svc_dir;

    $self->{+LOG_NAME}                  //= 'run';
    $self->{+NAME}                      //= "run-$self->{+RUN_ID}";
    $self->{+HARNESS_NAME}              //= 'harness';
    $self->{+JOB_ID}                    //= gen_uuid();
    $self->{+KILL_TIMEOUT}              //= 15;
    $self->{+PARENT_PIDS}               //= [];
    $self->{+STATE}                     //= 'running';
    $self->{+RESOURCE_SERVICES}         //= {};
    $self->{+TEST_JOBS}                 //= {};
    $self->{+COMPLETED_JOB_IDS}         //= {};
    $self->{+COMPLETED_JOB_STATES}      //= {};
    $self->{+PENDING_SYNTH_COMPLETIONS} //= {};
    $self->{+WATCH_PIDS}                //= [@{$self->{+PARENT_PIDS}}];
    $self->{+OWN_PGROUP}                //= 0;
    $self->{+COLLECTOR_GRACE_SECS}      //= DEFAULT_COLLECTOR_GRACE_SECS;

    # Run-level pass/fail latched by run_failing emission. Starts undef
    # (no jobs seen yet); flips to 1 implicitly on first successful job
    # observation, and to 0 on the first failing job (which also emits
    # run_failing into the local event stream).
    $self->{+RUN_PASS}               = 1;
    $self->{+RUN_FAILING_EMITTED}    = 0;
    $self->{+RUN_COMPLETED_EMITTED}  = 0;

    # Logger / observer plumbing was removed in the new_log_refactor
    # (M2 step 4+5); ignore any lingering caller-supplied slots.
    delete $self->{loggers};
    delete $self->{test_loggers};

    # The Run is now an immutable spec; lifecycle state lives on a
    # paired Run::State the run service owns. Construct the State
    # alongside, seed pending with every job_id, and seed per-job
    # results entries with queue-time metadata so downstream consumers
    # (the streamer in particular) can identify every job and order
    # lifecycle events by Time::HiRes stamp without having to cross-
    # reference the jobs array themselves. Entries are filled in
    # further as the job moves through started -> completed.
    my $rstate = $self->{+RUN_STATE} //= Test2::Harness2::Run::State->new(
        run_id     => $self->{+RUN_ID},
        created_at => $run->created_at,
    );
    croak "'run_state' must be a Test2::Harness2::Run::State, got " . (blessed($rstate) || ref($rstate) || '(scalar)')
        unless blessed($rstate) && $rstate->isa('Test2::Harness2::Run::State');

    $rstate->seed_pending(map { $_->job_id } @{$run->jobs})
        unless @{$rstate->pending};

    my $queued_at = time;
    for my $job (@{$run->jobs}) {
        my $jid = $job->job_id;
        my $tf  = $job->test_file;
        $rstate->seed_job_result(
            $jid,
            queued_at => $queued_at,
            job_try   => $job->job_try,
            abs_file  => $tf->absolute,
            rel_file  => $tf->relative,
        );
    }
}

# IPC::Manager::Role::Service contract (orig_io, pid, set_pid,
# watch_pids, handle_request) and the default request_handler_terminate
# come from Test2::Harness2::Role::Service. Service-specific handlers
# start here.

# Harness-to-RunService IPC: launch a test job under this run. The
# harness has already done scheduling (needed / available / assign);
# we only spawn the Collector and track its pid, so that the test
# process lives inside the run's subtree and the run service can reap
# it, forward its exit status back, and enforce shutdown cascades.
sub request_handler_launch_job {
    my ($self, $payload) = @_;
    $payload //= {};

    return {ok => 0, error => 'run service not accepting launches'}
        if $self->{+STATE} ne 'running';

    for my $required (qw/job_id test_file/) {
        return {ok => 0, error => "'$required' is required"}
            unless defined $payload->{$required};
    }

    my $job_id   = $payload->{job_id};
    my $job_try  = $payload->{job_try} // 1;
    my $run_id   = $payload->{run_id}  // $self->{+RUN_ID};
    my $log_file = $payload->{log_file};
    my $env      = $payload->{env} // {};
    my $auditor  = $payload->{auditor};
    my $test_file_abs   = $payload->{test_file};
    my $launch_cmd      = $payload->{launch};

    return {ok => 0, error => "'test_file' must be absolute"}
        unless File::Spec->file_name_is_absolute($test_file_abs);

    # The harness's unavailable-action skip / unavailable-action fail
    # paths hand us an explicit launch command (perl -e '...').
    # Default to running the real test file when no override is
    # present. When the launch payload's env carries
    # T2_HARNESS_INCLUDES (forwarded by Test2::Harness2::_launch_job),
    # turn it into -I flags so the child's @INC actually picks the
    # paths up -- the env var alone is not enough since exec(perl ...)
    # starts a fresh interpreter.
    if (!defined $launch_cmd) {
        my @extra_inc;
        if (my $payload_env = $payload->{env}) {
            my $inc = $payload_env->{T2_HARNESS_INCLUDES};
            @extra_inc = grep { length && $_ ne '.' } split /;/, $inc
                if defined $inc && length $inc;
        }
        $launch_cmd = [$^X, (map { "-I$_" } @extra_inc), '-Ilib', $test_file_abs];
    }

    $log_file //= undef;

    my $test_file_spec = Test2::Harness2::TestFile->new(file => $test_file_abs);

    # queued_at is recorded once per job at run service init in
    # _seed_run_state. Pull it back out here so the per-job
    # spec.jsonl artifact carries the queue-time stamp -- renderers
    # use it instead of the (now-retired) run_mutation snapshot.
    my $queued_at;
    if (my $rs = $self->{+RUN_STATE}) {
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
            launch       => $launch_cmd,
            new_pgroup   => 1,
            parent_pids  => [$$],
            env_vars     => {T2_FORMATTER => 'Stream2', %$env},
            logdir       => $self->{+LOGDIR},
            ipcm_info    => $self->ipcm_info,
            ipc_parent   => $self->{+NAME},
            ipc_run      => $self->{+NAME},
            ipc_harness  => $self->{+HARNESS_NAME},
            kill_timeout => $self->{+KILL_TIMEOUT},
            spec         => {
                test_file => $test_file_spec->TO_JSON,
                run_id    => $run_id,
                job_id    => $job_id,
                job_try   => $job_try,
                (defined $queued_at ? (queued_at => $queued_at) : ()),
            },
            (defined $auditor ? (auditor => $auditor) : ()),
        );
        1;
    };
    my $spawn_err = $@;

    unless ($spawn_ok) {
        return {ok => 0, error => "collector spawn failed: $spawn_err"};
    }

    my $pid = $handle->pid;
    $self->{+TEST_JOBS}->{$pid} = {
        job_id     => $job_id,
        job_try    => $job_try,
        run_id     => $run_id,
        pid        => $pid,
        handle     => $handle,
        log_file   => $log_file,
        started_at => time,
    };

    # NOTE: do not register the collector pid as an IPC::Manager worker.
    # The role's reap_children silently consumes worker-pid exits without
    # calling run_on_pid, so we would never see the exit and the harness
    # would never learn the job completed. Keeping it out of the worker
    # map routes the exit through run_on_pid where we forward it via
    # test_job_completed.
    return {ok => 1, pid => $pid, log_file => $log_file};
}

sub request_handler_status {
    my $self = shift;

    my @services;
    for my $svc (values %{$self->{+RESOURCE_SERVICES} // {}}) {
        push @services => {
            pid           => $svc->{pid},
            name          => $svc->{name},
            service_class => $svc->{service_class},
            log_path      => $svc->{log_path},
            restartable   => $svc->{restartable},
            resource      => $svc->{resource}->resource_name,
        };
    }

    my @jobs;
    for my $job (values %{$self->{+TEST_JOBS} // {}}) {
        push @jobs => {
            pid        => $job->{pid},
            run_id     => $job->{run_id},
            job_id     => $job->{job_id},
            job_try    => $job->{job_try},
            log_file   => $job->{log_file},
            started_at => $job->{started_at},
        };
    }

    return {
        service => {
            name     => $self->{+NAME},
            log_name => $self->{+LOG_NAME},
            pid      => $$,
            job_id   => $self->{+JOB_ID},
            workdir  => $self->{+WORKDIR},
            run_id   => $self->{+RUN_ID},
            state    => $self->{+STATE},
        },
        resource_services => \@services,
        test_jobs         => \@jobs,
    };
}

# Role::Service provides run_on_start. These hooks tack on the
# run-specific extras: run_id in the service_started event and
# bringing up the run's resource services. The initial Run snapshot
# is handled by the JSON logger on the interpose collector (via
# run_mutation events we emit on every state change); the legacy
# RunService-side snapshot writer is gone.
sub service_started_fields {
    my $self = shift;
    return (run_id => $self->{+RUN_ID});
}

sub service_on_start {
    my $self = shift;

    # Stamp the start time on the State so the persisted state.json
    # has it the moment any consumer reads it. Idempotent.
    $self->{+RUN_STATE}->mark_started;

    # Mirror the start stamp on our own slot so the collector_report
    # facet emitted at shutdown can carry it without round-tripping
    # through Run::State.
    $self->{+STARTED_AT} //= time;

    # Skinny run-level transition events. Renderers consume these
    # plus per-job spec.jsonl / report.jsonl artifacts; the bulky
    # full-snapshot run_mutation event was retired (it shipped a
    # complete results map on every state change, growing O(N^2)
    # with job count). Authoritative state mirroring still flows
    # to the harness via the run_state_update IPC channel below.
    my @job_ids = map { $_->job_id } @{$self->{+RUN}->jobs};
    $self->_emit_run_log_event(
        kind       => 'run_queued',
        queued_at  => $self->{+RUN}->created_at,
        total_jobs => scalar(@job_ids),
        job_ids    => \@job_ids,
    );
    $self->_emit_run_log_event(
        kind       => 'run_started',
        started_at => $self->{+STARTED_AT},
    );

    # Authoritative full-snapshot mirror to the harness. IPC only;
    # nothing on disk.
    $self->_send_run_state_to_harness;

    # Bring up the run's resource services. The harness has already
    # validated the resource set (needed + non-permanent) before
    # spawning us; we just start whatever is configured.
    my $resources = $self->{+RUN}->resources // [];
    $self->start_resource_services($resources, scope => 'run', run => $self->{+RUN})
        if @$resources;

    return;
}

sub run_on_all {
    my ($self, $activity) = @_;

    # Reap any descendants quickly; IPC::Manager's tick drives
    # run_on_pid for exits, so there's nothing more for us to do here
    # beyond letting the loop roll over.
    return;
}

sub run_on_pid {
    my ($self, $pid, $exit) = @_;

    # Test-collector exit. The authoritative completion message
    # (test_job_completed) now flows through the collector's own
    # TestObserver after the auditor has consumed harness_job_exit
    # and stamped the final verdict into the payload. If that
    # message already arrived, we just clear our tracking entry.
    # Otherwise we arm a grace timer so the watchdog in
    # run_on_interval can synthesize completion if nothing comes
    # in -- collector may have crashed before it got to emit.
    if (my $job = delete $self->{+TEST_JOBS}->{$pid}) {
        my $job_id = $job->{job_id};

        if ($self->{+COMPLETED_JOB_IDS}->{$job_id}) {
            # The collector already told us it was done; the exit
            # we just reaped is the matching post-emit reap.
            return;
        }

        $self->{+PENDING_SYNTH_COMPLETIONS}->{$job_id} = {
            %$job,
            pid_gone_at      => time,
            raw_exit_on_reap => $exit,
        };
        return;
    }

    # Resource-service exit (handled by the shared host role).
    # Reparented descendants that aren't one of ours silently fall
    # through.
    $self->handle_resource_service_exit($pid, $exit);

    return;
}

# Collector-side watchdog: if a collector pid disappeared without
# test_job_completed being received, synthesize completion once the
# grace window expires. IPC::Manager drives run_on_interval every
# ~0.2s so the resolution is sub-second even though the grace
# window is seconds-scale.
sub run_on_interval {
    my $self = shift;

    my $pending = $self->{+PENDING_SYNTH_COMPLETIONS} or return;
    return unless keys %$pending;

    my $now   = time;
    my $grace = $self->{+COLLECTOR_GRACE_SECS} // DEFAULT_COLLECTOR_GRACE_SECS;

    for my $job_id (keys %$pending) {
        my $entry = $pending->{$job_id};

        # Did a real test_job_completed arrive during the grace
        # window? Drop the pending synth.
        if ($self->{+COMPLETED_JOB_IDS}->{$job_id}) {
            delete $pending->{$job_id};
            next;
        }

        next if ($now - $entry->{pid_gone_at}) < $grace;

        warn sprintf(
            "RunService: synthesizing test_job_completed for job %s " . "(collector pid %d): no test_job_completed in %ds after pid exit\n",
            $job_id, $entry->{pid} // 0, $grace,
        );

        delete $pending->{$job_id};

        my $raw = $entry->{raw_exit_on_reap};
        $self->_handle_gen_msg_test_job_completed({
            run_id     => $entry->{run_id},
            job_id     => $job_id,
            job_try    => $entry->{job_try},
            exit       => $raw,
            # Explicitly stamp a failed-with-zero-counts result so
            # downstream renderers can distinguish "synthesized
            # completion of a vanished collector" from "completion with
            # unknown counts". Undef pass_count / fail_count would
            # otherwise propagate to the renderer surface.
            pass       => 0,
            pass_count => 0,
            fail_count => 0,
            stamp      => time,
            synth      => 1,
        });
    }

    return;
}

# Incoming IPC messages from test-job collectors (and their
# observers). IPC::Manager::Role::Service feeds every non-request
# message here after message-handler dispatch has already looked for
# a matching request_handler_*. The harness aggregates its own shadow
# Run by consuming run_state_update messages we produce here.
#
# Dispatch is name-prefixed (_handle_gen_msg_${kind}) so the per-kind
# handlers live in their own namespace and cannot collide with
# unrelated method names. Unknown kinds are silently dropped, same
# as the previous explicit-elsif chain.
sub run_on_general_message {
    my ($self, $msg) = @_;

    my $content = $msg->content;
    my $kind    = ref($content) eq 'HASH' ? $content->{kind} : undef;
    return unless defined $kind;

    my $method = "_handle_gen_msg_$kind";
    return unless $self->can($method);
    return $self->$method($content);
}

sub _handle_gen_msg_test_job_started {
    my ($self, $content) = @_;

    my $job_id = $content->{job_id} // return;

    # Record collector + test pids on our tracking entry so the
    # watchdog (added in a later commit) and any status queries see
    # the live pids the collector reported.
    if (my $info = $self->_job_tracking_by_collector_pid($content->{collector_pid})) {
        $info->{collector_pid}       //= $content->{collector_pid};
        $info->{test_pid}            //= $content->{test_pid};
        $info->{started_at_reported} //= $content->{stamp} // time;
    }

    # Mutate Run state: pending -> running. Guard with an eval so an
    # out-of-order started message (should not happen but: belt +
    # suspenders) doesn't take the service down.
    my $ok  = eval { $self->{+RUN_STATE}->mark_running($job_id); 1 };
    my $err = $@;
    warn "run service could not mark job '$job_id' running: $err" unless $ok;

    my $started_at = $content->{stamp} // time;
    $self->{+RUN_STATE}->seed_job_result($job_id, started_at => $started_at);

    $self->_emit_run_log_event(
        kind     => 'job_started',
        stamp    => $started_at,
        job_info => {
            run_id  => $content->{run_id},
            job_id  => $job_id,
            job_try => $content->{job_try},
        },
    );

    $self->_send_run_state_to_harness;
    return;
}

sub _handle_gen_msg_test_job_diagnosing {
    my ($self, $content) = @_;

    $self->_emit_run_log_event(
        kind     => 'job_diagnosing',
        stamp    => time,
        job_info => {
            run_id  => $content->{run_id},
            job_id  => $content->{job_id},
            job_try => $content->{job_try},
        },
    );
    return;
}

sub _handle_gen_msg_test_job_failing {
    my ($self, $content) = @_;

    $self->_emit_run_log_event(
        kind     => 'job_failing',
        stamp    => time,
        job_info => {
            run_id  => $content->{run_id},
            job_id  => $content->{job_id},
            job_try => $content->{job_try},
        },
    );

    # First failing job in the run -- flip run_pass to 0 and emit
    # run_failing into our local event stream so the run collector
    # records it in runs/<id>/events.jsonl.zst. Subsequent failing
    # jobs do not re-emit (state-flip event, not per-failure
    # broadcast).
    if (!$self->{+RUN_FAILING_EMITTED}) {
        $self->{+RUN_FAILING_EMITTED} = 1;
        $self->{+RUN_PASS}            = 0;

        $self->_emit_run_failing(
            job_id  => $content->{job_id},
            job_try => $content->{job_try},
        );
    }

    return;
}

# Emit run_failing on the run service's own outgoing event stream.
# Run collector picks it up via the standard pipeline and writes a
# row carrying the harness facet under runs/<id>/events.jsonl.zst.
sub _emit_run_failing {
    my ($self, %fields) = @_;

    my $em = $self->{+EMITTER} or return;

    $em->emit_event(
        run_failing => {
            run_id  => $self->{+RUN_ID},
            job_id  => $fields{job_id},
            job_try => $fields{job_try},
            stamp   => time,
        },
    );

    return;
}

# Reflect a collector_start IPC from a child collector (job or
# run-scoped service) into our own outgoing event stream. The run's
# collector picks it up via the standard pipeline and writes a
# harness_collector_start row into runs/<run_id>/events.jsonl.zst.
# This is the discovery hook a Log iterator uses to descend into
# the child collector's events.jsonl.zst.
sub _handle_gen_msg_collector_start {
    my ($self, $content) = @_;

    my $em = $self->{+EMITTER} or return;
    # Top-level facet (not nested in facet_data.harness) so the Log
    # iterator can spot it via $event->{facet_data}{harness_collector_start}
    # and descend into the child collector's events.jsonl.zst.
    $em->emit_raw({
        facet_data => {
            harness_collector_start => {%$content},
        },
    });

    return;
}

sub _handle_gen_msg_collector_end {
    my ($self, $content) = @_;

    my $em = $self->{+EMITTER} or return;
    $em->emit_raw({
        facet_data => {
            harness_collector_end => {%$content},
        },
    });

    return;
}

sub _handle_gen_msg_test_job_completed {
    my ($self, $content) = @_;

    my $job_id = $content->{job_id} // return;

    # Idempotent guard: the auditor-emitted message and the
    # watchdog-synthesized message can race. First one wins; the
    # second is dropped.
    return if $self->{+COMPLETED_JOB_IDS}->{$job_id};
    $self->{+COMPLETED_JOB_IDS}->{$job_id} = 1;
    delete $self->{+PENDING_SYNTH_COMPLETIONS}->{$job_id};

    # Stash the full per-job state hash so the run service's eventual
    # collector_report aggregate (M2 step 6+9) can be assembled from
    # in-memory state without disk reads (per F18). The payload from
    # Auditor::Test._emit_completed already carries every field we
    # need (pass/exit/plan/halt/counts/timing); just snapshot it.
    $self->{+COMPLETED_JOB_STATES}->{$job_id} = {%$content};

    # Flip the run's pass state if a job came in failing without
    # having previously emitted test_job_failing (e.g. a synthesized
    # completion of a vanished collector). The first run_failing
    # emission wins; subsequent flips are silent.
    if (!$content->{pass} && !$self->{+RUN_FAILING_EMITTED}) {
        $self->{+RUN_FAILING_EMITTED} = 1;
        $self->{+RUN_PASS}            = 0;

        $self->_emit_run_failing(
            job_id  => $content->{job_id},
            job_try => $content->{job_try},
        );
    }

    # Record the authoritative verdict + exit details keyed by
    # job_id so the State snapshot can carry them out to the harness
    # (via run_state_update) and any harness-side IPC consumer that
    # wants per-job pass/fail can read them without touching logs.
    # Merge (not replace) so queue-time seeding and started_at stay.
    my $completed_at = $content->{stamp} // time;
    $self->{+RUN_STATE}->record_job_result(
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

    # Mutate Run state: running -> done. Safe to call even if the job
    # was marked skipped earlier (mark_done croaks; we guard).
    my $ok  = eval { $self->{+RUN_STATE}->mark_done($job_id); 1 };
    my $err = $@;
    warn "run service could not mark job '$job_id' done: $err" unless $ok;

    # Skinny completion event: just enough for the renderer to flip
    # state. Detailed timing / counts / exit_decoded live in the per-
    # job report.jsonl artifact; renderers fetch on demand.
    $self->_emit_run_log_event(
        kind     => 'job_completed',
        stamp    => $content->{completed_at} // time,
        job_info => {
            run_id  => $content->{run_id},
            job_id  => $job_id,
            job_try => $content->{job_try},
        },
        pass => $content->{pass},
    );

    $self->_send_run_state_to_harness;
    return;
}

sub _job_tracking_by_collector_pid {
    my ($self, $pid) = @_;
    return undef unless defined $pid;
    return $self->{+TEST_JOBS}->{$pid};
}

# Emit a lifecycle event onto the run service's own emitter (which
# is the collector-interposed STDOUT of the service, i.e. it ends up
# in the run's .jsonl / .json log via the run-service collector's
# loggers).
sub _emit_run_log_event {
    my ($self, %fields) = @_;

    my $em = $self->{+EMITTER} or return;
    $em->emit_event(
        run_id => $self->{+RUN_ID},
        %fields,
    );
    return;
}

# Send a run_state_update IPC to the harness with the full
# State->TO_JSON snapshot so the harness's mirror stays authoritative.
# IPC only -- the on-disk run-events stream carries skinny transition
# events instead (run_queued / run_started / job_started /
# job_completed / run_failing / run_completed). Renderers reconstruct
# whatever per-job detail they need from spec.jsonl / report.jsonl
# artifacts.
sub _send_run_state_to_harness {
    my $self = shift;

    $self->_send_to_harness({
        kind     => 'run_state_update',
        run_id   => $self->{+RUN_ID},
        run_data => $self->{+RUN_STATE}->TO_JSON,
    });

    return;
}

sub _send_to_harness {
    my ($self, $msg) = @_;

    my $ok = eval {
        my $handle = IPC::Manager::Service::Handle->new(
            service_name => $self->{+HARNESS_NAME},
            ipcm_info    => $self->ipcm_info,
        );
        $handle->client->send_message($self->{+HARNESS_NAME}, $msg);
        1;
    };
    warn "RunService could not notify harness: $@" unless $ok;
    return;
}

sub run_should_end {
    my $self = shift;

    return 0 unless $self->{+STATE} eq 'terminating';

    # Wait until every resource service AND every test collector we
    # were tracking has exited before we let the loop unwind.
    return 0 if keys %{$self->{+RESOURCE_SERVICES} // {}};
    return 0 if keys %{$self->{+TEST_JOBS}         // {}};
    return 1;
}

sub run_on_cleanup {
    my $self = shift;

    # Final hard-stop in case we're unwinding without a prior terminate
    # (e.g. our parent died). Drain any remaining resource services and
    # test collectors.
    $self->perform_hard_stop
        if keys %{$self->{+RESOURCE_SERVICES} // {}}
        || keys %{$self->{+TEST_JOBS} // {}};

    for my $res (@{$self->{+RUN}->resources // []}) {
        my $ok  = eval { $res->teardown; 1 };
        my $err = $@;
        warn "resource '" . $res->resource_name . "' teardown died: $err"
            unless $ok;
    }

    # Stamp finish time + completed flag on the State so the persisted
    # snapshot reflects the terminal state.
    $self->{+RUN_STATE}->mark_finished;
    $self->{+ENDED_AT} //= time;

    # Final run_state_update IPC so the harness mirror sees the
    # terminal state before run_completed lands.
    $self->_send_run_state_to_harness;

    # Emit the terminal run_completed + collector_report event. The
    # run collector picks up the collector_report facet via its
    # write_phase and merges it into runs/<id>/report.jsonl.zst at
    # exit (per F3/F4: single event, two facets).
    $self->emit_run_completed;

    $self->emit_service_event(kind => 'service_stopped');
}

# Emit the terminal run_completed + collector_report two-facet event
# (per F4 = A). Built from in-memory COMPLETED_JOB_STATES plus the
# pass/start/end stamps the run service tracks itself.
sub emit_run_completed {
    my $self = shift;

    return if $self->{+RUN_COMPLETED_EMITTED};
    $self->{+RUN_COMPLETED_EMITTED} = 1;

    my $em = $self->{+EMITTER} or return;

    my $now    = time;
    my $report = $self->_build_collector_report($now);

    # Two-facet event per F4=A: harness.run_completed (state-flip
    # announcement) + top-level collector_report (data the run
    # collector merges into report.jsonl.zst via _capture_collector_report).
    # emit_raw -- not emit_event -- so collector_report lands at the
    # top of facet_data, not nested under harness.
    $em->emit_raw({
        facet_data => {
            harness => {
                run_id        => $self->{+RUN_ID},
                run_completed => {
                    run_id => $self->{+RUN_ID},
                    stamp  => $now,
                },
            },
            collector_report => $report,
        },
    });

    return;
}

# Walk COMPLETED_JOB_STATES (per-job state hashes the run service
# accumulated from each test_job_completed IPC -- per F18) and
# assemble the run-level aggregate the run collector merges into
# report.jsonl.zst.
sub _build_collector_report {
    my $self = shift;
    my ($now) = @_;
    $now //= time;

    my $states = $self->{+COMPLETED_JOB_STATES} // {};

    my $passed  = 0;
    my $failed  = 0;
    my $aborted = 0;

    my %jobs_by_id;
    for my $jid (keys %$states) {
        my $st = $states->{$jid} // {};
        my $job_pass = $st->{pass} ? 1 : 0;
        if ($job_pass) {
            $passed++;
        }
        else {
            $failed++;
            $aborted++ if $st->{synth};
        }

        # Resolve test file for this job from the Run's queue-time
        # job spec. Jobs that were only synthesized (no original
        # entry) won't have a Run::Job; fall back to whatever the
        # state hash carries.
        my $file = $st->{file};
        if (!defined $file) {
            for my $job (@{$self->{+RUN}->jobs}) {
                next unless $job->job_id eq $jid;
                my $tf = $job->test_file;
                $file = $tf->absolute if $tf;
                last;
            }
        }

        my $tries = defined($st->{job_try}) ? $st->{job_try} : 1;

        $jobs_by_id{$jid} = {
            job_id     => $jid,
            file       => $file,
            pass       => $job_pass,
            tries      => $tries,
            subtests   => [@{$st->{subtests} // []}],
        };
    }

    # Stable ordering: order from the Run's own jobs spec; any
    # remaining ids get appended in sort order so the array stays
    # deterministic.
    my @ordered;
    my %placed;
    for my $job (@{$self->{+RUN}->jobs}) {
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
        pass         => $self->{+RUN_PASS} ? 1 : 0,
        started_at   => $self->{+STARTED_AT},
        ended_at     => $self->{+ENDED_AT} // $now,
        total_jobs   => $total,
        passed_jobs  => $passed,
        failed_jobs  => $failed,
        aborted_jobs => $aborted,
        jobs         => \@ordered,
    };
}

# ----------------------------------------------------------------------
# Shutdown
# ----------------------------------------------------------------------

# Role::Service hooks. The shared escalator in Role::Service drives the
# TERM/KILL loop; these methods only feed and clean up the run-side
# tracking hashes.
sub hard_stop_pids {
    my $self = shift;

    my %pids;
    for my $info (values %{$self->{+RESOURCE_SERVICES} // {}}) {
        $pids{$info->{pid}} //= {} if $info->{pid};
    }
    for my $info (values %{$self->{+TEST_JOBS} // {}}) {
        $pids{$info->{pid}} //= {} if $info->{pid};
    }

    return %pids;
}

# Mid-loop reap hook: as the escalator reaps a pid, drop it from our
# tracking hashes too so run_should_end sees the updated counts on the
# next tick.
sub service_on_reaped {
    my ($self, $pid) = @_;
    delete $self->{+RESOURCE_SERVICES}->{$pid};
    delete $self->{+TEST_JOBS}->{$pid};
    return;
}

# Post-stop cleanup: anything still tracked after the escalator gave up
# has been IGNORE'd (alive after KILL + grace). Drop it so
# run_should_end sees empty maps.
sub service_post_hard_stop {
    my $self = shift;
    $self->{+RESOURCE_SERVICES} = {};
    $self->{+TEST_JOBS}         = {};
    return;
}

# ----------------------------------------------------------------------
# Emission helper
# ----------------------------------------------------------------------

sub emit_service_event {
    my ($self, %fields) = @_;

    my $em = $self->{+EMITTER} or return;    # no emitter in unit tests
    $em->emit_event(
        job_id => $self->{+JOB_ID},
        run_id => $self->{+RUN_ID},
        %fields,
    );

    return;
}

# ----------------------------------------------------------------------
# Entry points
# ----------------------------------------------------------------------

# Take over the current process as a run service. Mirrors the harness
# service's interpose pattern: fork once so the parent becomes the
# run-service collector (with the configured loggers writing the
# run's .jsonl and .json sidecars via the logger role's path rules),
# and the child continues as the actual run-service event loop with
# its STDOUT/STDERR piped through the collector.
sub start {
    my ($class, %args) = @_;

    croak "'ipcm_info' is required" unless defined $args{ipcm_info};

    my $caller_pid = $$;
    $args{parent_pids} //= [$caller_pid];

    my $self = $class->new(%args);

    my $run_service = sub {
        $self->{+EMITTER} = Test2::Harness2::Util::EventEmitter->std;

        my $self_ref = $self;
        local $SIG{TERM} = sub { $self_ref->{+STATE} = 'terminating' };

        my $exit = $self->run;
        POSIX::_exit($exit // 0);
    };

    # The run collector lives under runs/<run_id>/ -- type='Run' with
    # id=<run_id>. The run service is the collector's "parent service"
    # for IPC purposes (so the run service can ingest its own
    # collector_start/end into runs/<run_id>/events.jsonl.zst once
    # M2 step 6 lands).
    Test2::Harness2::Collector->interpose(
        type         => 'Run',
        id           => $self->{+RUN_ID},
        run_id       => $self->{+RUN_ID},
        ipcm_info    => $self->ipcm_info,
        ipc_parent   => $self->{+HARNESS_NAME},
        ipc_run      => $self->{+NAME},
        ipc_harness  => $self->{+HARNESS_NAME},
        bus_id       => "collector:run:" . $self->{+RUN_ID},
        logdir       => $self->{+LOGDIR},
        parser       => 'Test2::Harness2::Collector::Parser::IOParser',
        parent_pids  => [$caller_pid],
        kill_timeout => $self->{+KILL_TIMEOUT},
        spec         => {
            run_id   => $self->{+RUN_ID},
            run_uuid => $self->{+RUN}->run_uuid,
            name     => $self->{+NAME},
            harness  => $self->{+HARNESS_NAME},
        },
    );

    $run_service->();
}

# Fork a run service from the calling process (typically the harness).
# Shares the caller's ipcm_info so both services are on the same bus.
# Returns the child pid in the parent; the child never returns from
# this call.
sub spawn {
    my ($class, %args) = @_;

    croak "'ipcm_info' is required" unless defined $args{ipcm_info};
    croak "'run' is required"       unless defined $args{run};

    my $parent_pid = $$;
    $args{parent_pids} //= [$parent_pid];

    my $pid = fork // die "fork: $!";

    # Parent: just return the pid. Ready-state is signalled via
    # service_started appearing on the IPC bus, but callers that
    # don't need the signal can fire-and-forget.
    return $pid if $pid;

    # Child: take over the process and run the service loop.
    $class->start(%args);
    POSIX::_exit(255);    # start() should never return
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::RunService - Per-run supervisor service forked by the
harness for every test run.

=head1 DESCRIPTION

Every time L<Test2::Harness2> accepts a run for launch it forks one of
these as a child process. The run service exists for the lifetime of
the run and has two jobs:

=over 4

=item * Host the run's resource services

Per-run resources (those attached to C<< $run->resources >>) have their
C<service_*> methods invoked here, so any subprocess a resource spawns
is a grandchild of the harness and a direct child of the run service.
The process tree mirrors the ownership model: per-run services live
under their run, not under the harness.

=item * Produce a collected per-run log

Its stdout and stderr are piped through the standard collector with
loggers attached, so every run has a C<runs/E<lt>run_idE<gt>/services/E<lt>nameE<gt>.jsonl>
file that records C<service_started>, C<service_stopped>, and any
diagnostic output the run service or its children emit.

=back

The run service is started even when the run has no resources attached
-- the per-run log is useful on its own, and the consistent shape means
downstream tooling doesn't have to special-case runs with no resources.

Scheduling stays in L<Test2::Harness2> itself; the run service does not
make launch decisions.

=head1 ATTRIBUTES

=over 4

=item workdir (required)

Working directory for the run (the same one the harness uses).

=item run (required)

The L<Test2::Harness2::Run> being supervised.

=item run_id

Defaulted from C<< $run->run_id >>.

=item name

Service name. Defaults to C<'run'>; the name determines the log file:
C<< <workdir>/runs/<run_id>/services/<name>.jsonl >>. Also reserved in
this run's per-run service-name scope so a resource service can't
collide with it.

=item ipcm_info (required for spawn/start)

L<IPC::Manager> bus info. Typically inherited from the harness.

=item parent_pids

Pids the service should self-terminate with. Defaults to the caller
(harness) pid.

=item kill_timeout

Seconds to wait between TERM and KILL during shutdown. Default C<15>.

=back

=head1 METHODS

=over 4

=item $pid = Test2::Harness2::RunService->spawn(%args)

Fork from the caller and launch a run service child. Returns the pid
in the parent; the child never returns.

=item Test2::Harness2::RunService->start(%args)

Run the service loop in the current process (after the harness has
already forked). Does not return.

=item $rv = $svc->request_handler_terminate

IPC handler: initiate a hard stop. TERMs tracked resource services
(escalating to KILL after C<kill_timeout> seconds) and exits.

=item $rv = $svc->request_handler_status

IPC handler: snapshot of the run service state including every tracked
resource service.

=back

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

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
