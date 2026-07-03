package Test2::Harness2::Runner::Role::Service::Handlers;
use v5.38;

our $VERSION = '2.000000';

use Time::HiRes qw/time/;

use Test2::Harness2::Runner::StatusReport();

use Role::Tiny;

# Constant-only slots (#17 pattern): grep/typo safety on the runner-hash keys this
# role touches. job_pids is owned by the runner; service_peers by Role::Service.
# Role::Tiny does not share HashBase constants, so each role declares its own.
use Test2::Harness2::Util::HashBase qw{
    +job_pids
    +service_peers
};

requires qw/state settings/;

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::Role::Service::Handlers - The runner's socket request
handlers.

=head1 DESCRIPTION

This role carries the request/response half of L<Test2::Harness2::Runner>. It is
the set of C<request_handler_*> methods the L<Test2::Harness2::Role::Service> loop
dispatches to (run/task/spawn submission, stage outcome reports,
status/abort/reload queries, subscription), plus the Role::Service framing
callbacks (C<service_conn_closed>, C<service_identified>) and the owner-drop run
sweep.

The completion-decision + terminate/abort machinery lives in
L<Test2::Harness2::Runner::Role::Service::Completion>, and the transition hub +
announce forwarding in L<Test2::Harness2::Runner::Role::Service::TransitionHub>;
both are composed into the same runner, so the cross-role calls here
(C<collector_conn_eof>, C<announce_job>, C<announce_system_load>, C<monitor>)
resolve on C<$self>.

It is composed into the runner alongside L<Test2::Harness2::Role::Service> and
L<Test2::Harness2::Runner::Role::Scheduler>; every method here is a method on the
runner C<$self> and shares its hashref slots and its other composed methods
(C<state>, C<forward_frame>, C<add_subscriber>).

=head1 SYNOPSIS

    package Test2::Harness2::Runner;
    use Role::Tiny::With;
    with 'Test2::Harness2::Runner::Role::Service::Handlers';

=head1 PUBLIC METHODS

=over 4

=item $self->record_job_pid($job_id, $pid)

Record a started job's pid in the runner's in-memory map.

=item $resp = $self->request_handler_E<lt>typeE<gt>($payload, $conn)

The socket request handlers; see the inline documentation for each.

=item $self->service_conn_closed($conn)

L<Test2::Harness2::Role::Service> calls this when a peer connection closes.
Dispatch by connection kind: a registered test-collector connection EOF runs the
completion decision (C<collector_conn_eof>); a command/run-owner connection runs
the connection-gated run sweep (abort the running ones / purge the finished ones).

=item $self->service_identified($conn, $payload)

L<Test2::Harness2::Role::Service> calls this when a peer announces its full
identity. A test collector's identity carries C<job_id> + C<job_try> (+ C<run_id>);
register the connection so its later EOF maps back to the job.

=item $self->handle_owner_drop($run_id, $info)

Act on one run whose owning connection dropped: purge it if finished, abort it if
running with C<abort_on_disconnect> true, or detach it (leave it running) if false.

=back

=cut

# Run submission rides runner.socket: a transient `yath test` command connects
# to runner.socket and sends one-way request frames. The runner receives them
# here and enqueues them through the canonical State's public queue_* methods,
# which apply each action in-process. The runner is the sole owner of its
# scheduling state -- it dispatches tasks to its stage services over sockets and
# folds their outcomes back in (there is no shared action log or file reader).
# The persistent run/spawn/abort path submits the same way over the socket.
#
# These are one-way requests: the role's _service_conn sends no reply when a
# handler returns undef. Ordering is preserved because the command sends them
# over a single connection and the FrameBuffer drains frames in order.
# Run/task submissions go through submit_action, which applies them to
# State immediately on every path EXCEPT the scheduler-only preload-root path before
# the stage map + base-stage resolver are ready -- there it buffers them and replays
# them in order once ready (a task cannot be bucketed by stage until then).
sub request_handler_queue_run {
    my $self = shift;
    my ($payload, $conn) = @_;

    # Surface any tolerated preload-load warnings (e.g. a broken preload
    # on the persistent path) at the START of each run, so a `yath run` client sees
    # them. Emitting to STDERR here lands them in runner-events within the run's
    # render window, where the run's Driver renders them tagged INTERNAL.
    if (my $warnings = $self->{'preload_warnings'}) {
        print STDERR $_ for @$warnings;
    }

    my $run = $payload->{run};

    # #110: reject a malformed frame with a per-request error BEFORE touching State
    # (run_owners / submit_action / the submit buffer, whose later flush_submit_buffer
    # replay the dispatch eval cannot guard). Shape only -- hashref presence -- per
    # #118's division of labor (#118 owns the category/duration domain checks).
    return {ok => 0, error => "queue_run request is missing its 'run' payload (expected a hashref)"}
        unless ref($run) eq 'HASH';

    # Ticket #12 / ARCHITECTURE.md §4.2: record the connection that queued this run as
    # its owner, plus that peer's pid (the §5.2 identity handshake) and the run's
    # abort_on_disconnect flag (default true). Retention and teardown are gated on this
    # owner connection -- when it drops, the runner's owner-drop sweep
    # (service_conn_closed) either aborts the still-running run or purges the finished
    # one. queue_task / stop_run stay accepted from ANY connection; only this is
    # owner-gated. Recorded only on the state hub (the root runner); a forked stage
    # service does not own run retention.
    if (defined($conn) && $self->{'rootpid'} == $$ && $run && defined $run->{run_id}) {
        $self->{'run_owners'}->{$run->{run_id}} = {
            conn                => $conn,
            peer_pid            => $conn->peer_pid,
            abort_on_disconnect => (exists $run->{abort_on_disconnect} ? ($run->{abort_on_disconnect} ? 1 : 0) : 1),
        };
    }

    $self->submit_action('queue_run', $run);
    return undef;
}

# Ticket #12 / ARCHITECTURE.md §4.2: Role::Service calls this when any peer
# connection closes (its _drop_conn hook). Sweep the runs this connection owns (it
# queued them) and act on the owner drop: a still-running run is aborted (if its
# abort_on_disconnect is true) or detached (if false); a finished, retained run is
# purged. Other connections' runs are untouched, so a persistent runner's in-memory
# run state is bounded by live owner connections, not by total runs ever queued.
sub service_conn_closed {
    my $self = shift;
    my ($conn) = @_;

    return unless $self->{'rootpid'} == $$;
    return unless defined $conn;

    # A test collector's connection EOF is the "collector gone" signal and the
    # point at which the runner decides the test's outcome (ARCHITECTURE.md §5.4).
    # Dispatch by connection kind: a registered test-collector connection runs the
    # completion decision; a command/run-owner connection runs the owner-drop sweep.
    # These are disjoint -- a test-collector connection never owns a run.
    return $self->collector_conn_eof($conn)
        if $self->{'collector_conns'} && $self->{'collector_conns'}{"$conn"};

    my $owners = $self->{'run_owners'} or return;

    for my $run_id (keys %$owners) {
        my $info = $owners->{$run_id};
        next unless ($info->{conn} // 0) == $conn;
        $self->handle_owner_drop($run_id, $info);
    }

    return;
}

# A peer announced its full identity. A test collector's identity carries job_id
# + job_try (+ run_id); register the connection -> job map so the connection's
# later EOF maps back to the job and its try (ARCHITECTURE.md §5.4). A non-test
# identity (a stage, a command, the preload-root) carries no job_id and is
# ignored here. If the run is already under a bail/abort intent (a job that
# connected AFTER the bail), terminate this late collector right now.
sub service_identified {
    my $self = shift;
    my ($conn, $payload) = @_;

    return unless $self->{'rootpid'} == $$;
    return unless $conn && ref($payload) eq 'HASH';

    my $job_id = $payload->{job_id} // return;

    my $entry = {
        conn    => $conn,
        job_id  => $job_id,
        job_try => $payload->{job_try},
        run_id  => $payload->{run_id},
        pid     => $payload->{pid},
    };

    $self->{'collector_conns'}{"$conn"} = $entry;
    $self->{'collector_current_try'}{$job_id} = $payload->{job_try};

    # Record the collector's pid for the status report (and the kill(-pid) abort
    # fallback). The runner learns it HERE, from the collector's own handshake, for
    # BOTH paths: no-preload collectors are the runner's direct children (also
    # recorded at run_job), and preload collectors double-fork + detach (ticket #28)
    # so the stage no longer reports their pid -- this handshake is the only source.
    $self->record_job_pid($job_id, $payload->{pid}) if defined $payload->{pid};

    # The collector connected: the connect-timeout no longer applies to this job
    # (its completion now rides this connection's transitions + EOF).
    delete $self->{'job_connect_watch'}{$job_id};

    # Late-connecting collector for a run already bailing/aborting: terminate it
    # now so it kills its child and EOFs (handled as aborted, never a false pass).
    # This is the late-connect leg of the bail/abort intent (the assign->launch
    # race / B4): a job dispatched before the abort but only now connecting still
    # gets torn down, with no reliance on a possibly-stale pid snapshot.
    if (defined($entry->{run_id}) && $self->{'aborting_runs'} && exists $self->{'aborting_runs'}{$entry->{run_id}}) {
        $self->_terminate_collector($entry, $self->{'aborting_runs'}{$entry->{run_id}}{reason});
    }

    # Per-job late-connect teardown: a collector for a job already failed by the
    # connect-timeout (_enforce_collector_connect_timeout recorded the intent)
    # connected after its slot was reclaimed. Terminate it so its test child does
    # not run on as an orphan. Try-matched so a legitimate retry's collector is left
    # alone; the intent is consumed here (and otherwise swept at run end).
    if (my $ti = $self->{'terminated_jobs'} ? $self->{'terminated_jobs'}{$job_id} : undef) {
        my $same_try = !defined($ti->{job_try}) || !defined($payload->{job_try}) || "$ti->{job_try}" eq "$payload->{job_try}";
        if ($same_try) {
            delete $self->{'terminated_jobs'}{$job_id};
            $self->_terminate_collector($entry, $ti->{reason});
        }
    }

    return;
}

# Ticket #12 / ARCHITECTURE.md §4.2: act on a single run whose owner connection
# dropped. Retention is gated on the owner, NOT on completion:
#   finished -> purge the retained run (Run object + job states + raw item);
#   running + abort_on_disconnect true  -> abort: halt pending tasks, kill the run's
#       still-running jobs via the watchdog (run-scoped abort_remaining, which signals
#       their collectors), mark it stopped so the loop advances to the next run;
#   running + abort_on_disconnect false -> detach: leave it running, purge on
#       completion (clear_finished_run retains it; the finished branch fires if its
#       owner record is ever swept again, otherwise it lingers harmlessly until the
#       state is torn down).
# The owner record is dropped either way so the run is not swept twice.
sub handle_owner_drop {
    my $self = shift;
    my ($run_id, $info) = @_;

    # Drop the owner record first so an abort that ends the run (and could re-enter the
    # sweep) does not loop on this run.
    delete $self->{'run_owners'}->{$run_id};

    my $status = $self->state->run_status($run_id);

    # Finished and retained: the owner left, so purge it now (nothing will query it).
    if (defined($status) && $status eq 'finished') {
        $self->state->purge_run($run_id);
        return;
    }

    # Already gone (purged, or never reached state): nothing to do.
    return unless defined($status) && $status eq 'running';

    # Detach: keep the run going, purge it on completion. A future queue-and-detach
    # command sets abort_on_disconnect false; the run's results still persist.
    return unless $info->{abort_on_disconnect};

    # Abort: halt pending tasks + stop the run in canonical state, and kill its still-
    # running jobs (the watchdog signals their collectors). A vanished run/test command
    # means a crash or user kill, which intends to kill the run.
    $self->watchdog->abort_remaining(
        "Run aborted: the command that queued it disconnected",
        run_id => $run_id,
    );
    $self->state->abort_run($run_id);

    return;
}

# The preload-root reports preload-load warnings it tolerated (a broken
# preload skipped on the persistent path). Stored and re-emitted at each run start so
# they reach the run's output (the stage host does not exit, so they cannot ride
# stage_host_exited the way a transient fatal failure does).
sub request_handler_preload_warnings {
    my $self = shift;
    my ($payload) = @_;
    $self->{'preload_warnings'} = $payload->{warnings} if $payload && $payload->{warnings};
    return undef;
}

sub request_handler_queue_task {
    my $self = shift;
    my ($payload) = @_;

    # #110: shape-validate BEFORE touching State / the submit buffer. Hashref presence
    # plus the job_id/run_id keys queue_task funnels on; the category/duration domain
    # is #118's job (normalized in queue_task, not rejected here).
    my $task = $payload->{task};
    return {ok => 0, error => "queue_task request is missing its 'task' payload (expected a hashref)"}
        unless ref($task) eq 'HASH';

    my $job_id = $task->{job_id};
    return {ok => 0, error => "queue_task request task is missing its 'job_id'"}
        unless defined($job_id) && !ref($job_id);
    return {ok => 0, error => "queue_task request task is missing its 'run_id'"}
        unless defined($task->{run_id}) && !ref($task->{run_id});

    # A duplicate queue_task (e.g. a client retry after a timed-out ack -- plausible in
    # normal operation) is a per-request error, NOT a fatal die: the job is already
    # queued and re-queuing would double-dispatch it. Reject it here with a reply; the
    # queue_task funnel additionally drops any duplicate that slips past on the buffered
    # replay path (both copies buffered before the scheduler was ready) as a survivable
    # no-op the dispatch eval never sees.
    return {ok => 0, error => "queue_task request for job '$job_id' is a duplicate; that job is already queued"}
        if $self->state->task_queued($job_id);

    $self->submit_action('queue_task', $task);
    return undef;
}

sub request_handler_stop_run {
    my $self = shift;
    my ($payload) = @_;
    $self->submit_action('stop_run', $payload->{run_id});
    return undef;
}

sub request_handler_end_queue {
    my $self = shift;
    $self->submit_action('end_queue');
    return undef;
}

# A transient command that caught a signal asks the runner to halt the run over
# the socket. The runner stops scheduling tasks for the run and
# terminates its own job children through its normal signal/stop path; the command
# does not reconstruct state to kill individual job pids.
sub request_handler_halt_run {
    my $self = shift;
    my ($payload) = @_;
    $self->state->halt_run($payload->{run_id});
    return undef;
}

# A forked transient preload stage receives dispatched jobs on its own
# preload-<stage>.socket. The runner's in-process scheduler connects out and sends
# the already-resolved task (with the resources merged in) plus the run definition;
# the stage delegate queues it and the stage's run loop forks it from the preloaded
# interpreter. One-way: the runner does not read a reply.
sub request_handler_run_task {
    my $self = shift;
    my ($payload) = @_;

    # #110: a run_task frame belongs on a stage's preload-<stage>.socket, not on
    # runner.socket. Misdirected here, the runner's state hub (Runner::State) has no
    # enqueue_task and would die, unwinding the whole service loop. Shape-validate and
    # reject the misdirection with a per-request error instead of dying.
    my $task = $payload->{task};
    my $run  = $payload->{run};
    return {ok => 0, error => "run_task request is missing its 'task' payload (expected a hashref)"}
        unless ref($task) eq 'HASH';
    return {ok => 0, error => "run_task request is missing its 'run' payload (expected a hashref)"}
        unless ref($run) eq 'HASH';

    my $state = $self->state;
    return {ok => 0, error => "run_task was misdirected to the runner state hub; a run_task belongs on a stage socket"}
        unless $state->can('enqueue_task');

    $state->enqueue_task($task, $run);
    return undef;
}

# stop_task / retry_task verdict forwarding is GONE: a stage no longer reports a
# job's outcome to the runner. The runner decides every test's outcome (stop /
# retry / bail) from the collector's transitions + connection EOF on runner.socket
# (see service_conn_closed / collector_conn_eof, ARCHITECTURE.md §5.4).

# A monitored stage forwards a reload/monitor notification so the
# runner's reload state (diagnostics) stays current without a shared file. One-way.
sub request_handler_reload {
    my $self = shift;
    my ($payload) = @_;
    $self->state->reload($payload->{stage}, $payload->{data});
    return undef;
}

# The persistent `yath run` command checks the runner's reload state
# (per-stage source-file reload errors/warnings) before starting a run, so it can
# abort or prompt. It asks the runner over the socket. Two-way: returns the
# canonical reload_state hash. Only the root runner is the state authority.
sub request_handler_reload_state {
    my $self = shift;

    return {ok => 0, error => 'not the runner state hub'}
        unless $self->{'rootpid'} == $$;

    return {ok => 1, reload_state => $self->state->reload_state // {}};
}

# A no-side-effect liveness check (`yath ping`). Answer from ANY process the
# connection lands on (the root runner on runner.socket, or a stage) -- the point
# is just to prove the runner accepted a request and replied over the socket, and
# to report round-trip latency. It touches no state. Two-way: returns the ack,
# carrying this process's pid (so the caller can show which process answered) and a
# server-side timestamp.
sub request_handler_ping {
    my $self = shift;
    return {ok => 1, pid => $$, stamp => time};
}

# The persistent `status`/`ps`/`abort` commands ask the runner for
# its live scheduling state over runner.socket. The runner is the state authority;
# it builds a serializable report from its canonical State plus its in-memory
# job-pid map (it knows each job's pid when it forks it, or when a stage reports
# the pid of a job the stage forked). Two-way: returns the report hash.
sub request_handler_status {
    my $self = shift;

    return {ok => 0, error => 'not the runner state hub'}
        unless $self->{'rootpid'} == $$;

    my $report = Test2::Harness2::Runner::StatusReport->new(
        state      => $self->state,
        job_pids   => $self->{+JOB_PIDS},
        stage_pids => $self->stage_peer_pids,
    );

    return {ok => 1, status => $report->build};
}

# A transient/persistent root command asks the runner to truncate the queue
# (abort) over the socket. The runner truncates its own canonical state AND tears
# every running test down itself through the abort-intent + terminate primitive
# (ARCHITECTURE.md §5.4): it records an abort intent per still-running run and
# messages each live (and late-connecting) test collector to terminate, hard-killing
# any that do not comply within the grace. The command no longer snapshots pids or
# signals the jobs -- the old pid-snapshot raced a job whose pid had not yet been
# reported (B4); intent + terminate-on-connect closes that. `abort` still leaves the
# runner itself alive. Two-way: returns the still-running list (diagnostic only) +
# the count of collectors it terminated.
sub request_handler_truncate {
    my $self = shift;

    return {ok => 0, error => 'not the runner state hub'}
        unless $self->{'rootpid'} == $$;

    my $report = Test2::Harness2::Runner::StatusReport->new(
        state    => $self->state,
        job_pids => $self->{+JOB_PIDS},
    );

    my $running = $report->build->{running};

    # Record each still-running run's abort intent + terminate its collectors BEFORE
    # truncating the queue, so the intent is in place for any collector that connects
    # during teardown. The watchdog synthesizes each running job's aborted state +
    # marks it decided; the resulting collector EOFs are fire-once no-ops.
    my $reason = "Aborted by request";
    $self->watchdog->abort_remaining($reason);

    $self->state->truncate;

    return {ok => 1, running => $running};
}

# A2: the `resources` command asks the runner for its live resource status over
# runner.socket instead of constructing an observe-mode State that polled
# dispatch.jsonl. The runner owns the live resource objects (in its canonical
# State); it renders each resource's status_lines here -- the resource objects do
# not serialize, but their already-formatted status text does -- and returns the
# rendered text per resource so the command can print it verbatim. Two-way:
# returns the rendered resource list. Only the root runner is the state authority.
sub request_handler_resources {
    my $self = shift;

    return {ok => 0, error => 'not the runner state hub'}
        unless $self->{'rootpid'} == $$;

    my @out;
    for my $resource (@{$self->state->resources // []}) {
        my $lines = $resource->status_lines;
        next unless defined $lines && length $lines;
        push @out => {class => ref($resource), lines => $lines};
    }

    return {ok => 1, resources => \@out};
}

# The system-load sampler service (ARCHITECTURE.md §4.4) dials runner.socket and
# pushes one-way 'system_load' reports (a change-gated CPU/memory snapshot). Store
# the latest snapshot in canonical State so the throttling resources read one
# shared value, and announce a harness_system transition so it is logged + reaches
# subscribers (broadcast globally, latest retained for late subscribers). One-way:
# return undef so no response is sent.
sub request_handler_system_load {
    my $self = shift;
    my ($payload) = @_;

    return undef unless $self->{'rootpid'} == $$;

    my $load = $payload->{load} or return undef;

    $self->state->set_system_load($load);
    $self->announce_system_load($load);

    return undef;
}

# A forked preload stage forks a dispatched test job from its
# preloaded interpreter, so the stage -- not the runner -- knows the job's pid.
# It reports the pid back over runner.socket so the runner's job-pid map (used by
# the status/ps/abort report) is complete without a jobs.jsonl file. One-way.
sub request_handler_job_pid {
    my $self = shift;
    my ($payload) = @_;
    $self->record_job_pid($payload->{job_id}, $payload->{pid});
    return undef;
}

# Record a started job's pid in the runner's in-memory map (the runner's own
# forked jobs at run_job, a stage's forked jobs via the job_pid request). Cleared
# when the job's task stops so a future job that reuses a pid does not inherit a
# stale entry.
sub record_job_pid {
    my $self = shift;
    my ($job_id, $pid) = @_;

    return unless $self->{'rootpid'} == $$;
    return unless defined $job_id && defined $pid;

    $self->{+JOB_PIDS}->{$job_id} = $pid;

    return;
}

# bloat #3: put a started-but-never-accepted job back in the queue (the dispatch
# found its assigned stage gone, BEFORE the stage forked the job and took ownership
# of completion). This is the safe requeue: the stage never received the task, so no
# duplicate run can result. Releases the slot / resources and re-queues for
# re-resolution (State::requeue_task, no retry consumed), clears any job_pids entry,
# and forwards a non-terminal 'requeued' mutation (NOT 'done'/'aborted') so a
# subscriber's mirror moves the job back to pending rather than finalizing it.
sub requeue_task {
    my $self = shift;
    my ($task) = @_;

    my $job_id = $task->{job_id} // return;

    # A racing stop/abort may already have cleared it; treat that as a no-op.
    my $ok = eval { $self->state->requeue_task($job_id); 1 };
    return unless $ok;

    delete $self->{+JOB_PIDS}->{$job_id};

    $self->announce_job($job_id, 'requeued', file => $task->{file}, run_id => $task->{run_id});

    return;
}

# A transient stage reports it has bound its socket and is ready to be
# scheduled (or is going down at shutdown). The runner folds this into the same
# stage-readiness state its scheduler's _stage_order already gates on. One-way.
#
# Connection-currency (bloat #3): a stale stage report (from a prior preload-root
# incarnation, or a stage that has since been superseded) is rejected by checking
# the report's source connection against the connection currently registered as
# that stage's `preload-<stage>` peer. A report is honored only when it arrives on
# the connection the runner currently considers authoritative for that identity;
# a superseded connection's report is ignored -- the registered connection IS the
# live incarnation.
sub _stale_stage_report {
    my $self = shift;
    my ($payload, $conn) = @_;

    my $stage = $payload->{stage} // return 1;

    # No source connection means we cannot attribute the report; ignore it.
    return 1 unless $conn;

    my $current = $self->{+SERVICE_PEERS}{"preload-$stage"};

    # Before the stage's identity frame lands the peer may not be registered yet;
    # accept the report from the connection it arrived on (the registration and the
    # first report can race). Once a peer IS registered, only that exact connection
    # is current.
    return 0 unless $current;
    return $current == $conn ? 0 : 1;
}

sub request_handler_stage_ready {
    my $self = shift;
    my ($payload, $conn) = @_;
    return undef if $self->_stale_stage_report($payload, $conn);
    $self->state->stage_ready($payload->{stage});
    return undef;
}

sub request_handler_stage_down {
    my $self = shift;
    my ($payload, $conn) = @_;
    return undef if $self->_stale_stage_report($payload, $conn);
    $self->state->stage_down($payload->{stage});
    return undef;
}

# A stage announces it is intentionally reloading (restarting)
# before it exits to be respawned -- a richer label than the plain stage_down it
# would otherwise send. Same connection-currency guard as ready/down.
sub request_handler_stage_restarting {
    my $self = shift;
    my ($payload, $conn) = @_;
    return undef if $self->_stale_stage_report($payload, $conn);
    $self->state->stage_restarting($payload->{stage});
    return undef;
}

# The preload-root process (Test2::Harness2::Preload) dials the runner
# and asks for the preload list -- the runner no longer loads the preload
# libraries itself; the preload root does. Return the resolved -P/--preload module
# specs the user passed (the runner's `preloads`). Two-way. Only the root runner is
# the state hub.
sub request_handler_get_preload_list {
    my $self = shift;

    return {ok => 0, error => 'not the runner state hub'}
        unless $self->{'rootpid'} == $$;

    # Also hand the preload-root the REAL runner's pid. The preload-root
    # builds a stage-host Runner with this as its rootpid (so that Runner treats
    # itself as a stage, not the root) and conveys it down as watch_parent_pid to
    # every stage/job collector (ARCHITECTURE.md §4.1: collectors watch the runner).
    #
    # Also hand over monitor_preloads. The stage-host Runner uses it so
    # its preloader TOLERATES a broken preload (warn+skip) on the persistent path
    # (monitor on) but fails fast on the transient path (monitor off).
    return {
        ok               => 1,
        preloads         => [@{$self->preloads // []}],
        runner_pid       => $self->{'rootpid'},
        monitor_preloads => $self->monitor_preloads ? 1 : 0,
    };
}

# The preload-root loads the preload libraries, builds the stage map
# (which stages exist + which is default), and reports it here so the
# runner knows which stages to expect without loading any preload itself.
# The runner stores it. One-way is enough, but we ack so the preload root can
# confirm receipt. Only the root runner is the state hub.
sub request_handler_set_stage_data {
    my $self = shift;
    my ($payload) = @_;

    return {ok => 0, error => 'not the runner state hub'}
        unless $self->{'rootpid'} == $$;

    $self->{'reported_stage_data'} = $payload->{stage_data} // {};

    # If the scheduler-only State was already built (e.g. an early status
    # request) it captured an empty map; refresh its stage map now that the real
    # data has arrived, before any task is bucketed (submit_action buffers tasks
    # until the map + base stage are ready, so this lands first).
    if (my $state = $self->{'state'}) {
        if ($self->_preload_root_hosts_stages) {
            $state->set_stage_map($self->{'reported_stage_data'});
        }
    }

    return {ok => 1};
}

# The stage map the preload root reported, or undef before it has arrived.
# `has_reported_stage_data` is the readiness predicate the dispatch gate
# consults.
sub reported_stage_data     { $_[0]->{'reported_stage_data'} }
sub has_reported_stage_data { defined $_[0]->{'reported_stage_data'} ? 1 : 0 }

# The preload-root reports that its stage-host Runner has finished. If
# the scheduler-only runner is still waiting for a stage to register (a broken
# preload that died before any stage came up), this is the signal to stop waiting,
# fail the run, and surface the preload-root's captured error output. On a normal run
# the runner has long since passed that wait, so this just records the fact. One-way.
sub request_handler_stage_host_exited {
    my $self = shift;
    my ($payload) = @_;
    $self->{'stage_host_exited'} = 1;
    $self->{'stage_host_errors'} = $payload->{errors} if $payload && $payload->{errors};
    return undef;
}

sub stage_host_exited { $_[0]->{'stage_host_exited'} ? 1 : 0 }
sub stage_host_errors { $_[0]->{'stage_host_errors'} // [] }

# A client subscribes to the runner's canonical state. We register the
# connection as a persistent subscriber (it stays open and receives forwarded
# mutation frames asynchronously) and reply with a serialized snapshot of the
# whole canonical state so the client's local mirror starts whole. Unlike the
# one-way submission requests this returns a reply (the snapshot). Only the root
# runner is the state hub; a forked stage service does not serve subscriptions.
#
# Per-run routing: the request may carry a run_id; the subscriber is
# then scoped to that run -- its snapshot is filtered to that run (plus the global
# bucket) and forward_frame thereafter sends it only that run's frames. A
# subscribe with no run_id is a global subscriber (the watch path): it gets the
# whole snapshot and every forwarded frame.
sub request_handler_subscribe {
    my $self = shift;
    my ($payload, $conn) = @_;

    return {ok => 0, error => 'not the runner state hub'}
        unless $self->{'rootpid'} == $$;

    my $run_id = $payload->{run_id};

    $self->add_subscriber($conn, $run_id, $payload->{drain_gate}) if defined $conn;

    return {ok => 1, snapshot => $self->monitor->snapshot($run_id)};
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
