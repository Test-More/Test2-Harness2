package Test2::Harness2::Runner::Role::Service::Handlers;
use v5.38;

our $VERSION = '2.000000';

use Time::HiRes qw/time/;

use Test2::Collector::Util::Zstd qw/compress_blob/;
use Test2::Harness2::Util::JSON qw/encode_json/;

use Test2::Harness2::Runner::Monitor();
use Test2::Harness2::Runner::StatusReport();

use Role::Tiny;

requires qw/state settings/;

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::Role::Service::Handlers - The runner's socket request
handlers and transition hub.

=head1 DESCRIPTION

This role carries the request/response and transition-channel half of
L<Test2::Harness2::Runner>. It is the set of C<request_handler_*> methods the
L<Test2::Harness2::Role::Service> loop dispatches to (run/task/spawn submission,
stage outcome reports, status/abort/reload queries, subscription), plus the
transition hub that folds collector transitions into the canonical
L<Test2::Harness2::Runner::Monitor> and forwards both folded and
runner-originated mutations to subscribers.

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

=item $monitor = $self->monitor

Get the L<Test2::Harness2::Runner::Monitor> instance: the runner-side fold of
the collector transition channel.

=item $self->service_transition($payload, $frame, $conn)

L<Test2::Harness2::Role::Service> hands every transition frame here; fold it into
the monitor and forward it (verbatim) to that run's subscribers.

=item $self->announce_job($job_id, $state, %extra)

Fold and forward a runner-originated job mutation (dispatched / running / retry /
done) so a subscriber's mirror folds it identically.

=item $self->announce_run($run_id)

Fold and forward a runner-originated run-completion mutation.

=item $self->announce_run_health($run_id, $reason)

Report a post-pass collector failure: the runner reaped a collector with a
non-zero health exit after it had already reported a pass. The test stays green;
this flags the suite failed (a C<harness_run_health> mutation) so the command
exits non-zero, and prints the error to harness output.

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

=item $self->collector_conn_eof($conn)

Decide a test's outcome on its collector connection's EOF (drain done): the
verdict was captured on the connection as transitions arrived. Fire-once per
C<(job_id, job_try)>, stale-try guarded.

=item $self->mark_job_decided($job_id, $job_try)

=item $bool = $self->job_already_decided($job_id, $job_try)

The shared fire-once ledger keyed by C<(job_id, job_try)>: the EOF decision and
the watchdog both consult/set it so a job completes exactly once even when its EOF
and an abort race.

=item $self->handle_owner_drop($run_id, $info)

Act on one run whose owning connection dropped: purge it if finished, abort it if
running with C<abort_on_disconnect> true, or detach it (leave it running) if false.

=item $self->terminate_run_collectors($run_id, $reason)

=item $self->terminate_run_collectors($run_id, $reason, skip =E<gt> $entry)

The shared bail/abort teardown primitive: record an abort intent for the run (so a
late-connecting collector is terminated on connect) and send the runner-to-collector
terminate control to every live test collector of the run. The optional C<skip>
entry (a collector tearing its own child down) is not messaged.

=item $count = $self->abort_run_collectors($run_id, $reason)

Tear a run down through C<terminate_run_collectors> from the abort path (C<yath
abort> and owner-disconnect abort), returning the number of live run collectors it
messaged.

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

# The completion decision (ARCHITECTURE.md §5.4), run on a test collector's
# connection EOF after its transition frames have been drained. The verdict was
# captured on the conn -> job entry as transitions arrived. FIRE-ONCE: the shared
# decided_jobs ledger guarantees exactly one decision per (job_id, job_try) -- the
# EOF fires it; the reap (when it happens) is pure zombie cleanup and never decides.
#
# A stale-try EOF (the entry's job_try is not the job's current try -- a superseded
# attempt whose late EOF arrives after a retry already re-queued the job) is a
# no-op for stop/retry: it is only forgotten.
sub collector_conn_eof {
    my $self = shift;
    my ($conn) = @_;

    my $entry = delete $self->{'collector_conns'}{"$conn"} or return;

    my $job_id  = $entry->{job_id};
    my $job_try = $entry->{job_try};

    delete $self->{'job_pids'}->{$job_id} if defined $job_id;

    # Stale try: a superseded attempt's connection was retired on retry; its late
    # EOF must not stop/retry the live try (the current incarnation owns it).
    my $current = $self->{'collector_current_try'}{$job_id};
    return if defined($current) && defined($job_try) && "$current" ne "$job_try";

    # FIRE-ONCE: exactly one completion per (job_id, job_try). The decided set is
    # shared with the watchdog (an abort/owner-disconnect/wind-down abort marks the
    # job decided), so an EOF that arrives after the watchdog already decided this
    # try is a no-op, and vice versa. Per-entry/global both keyed here.
    return if $self->job_already_decided($job_id, $job_try);
    $self->mark_job_decided($job_id, $job_try);

    delete $self->{'collector_current_try'}{$job_id};

    $self->decide_collector_outcome($entry);

    return;
}

# The shared fire-once ledger keyed by (job_id, job_try): the EOF decision and the
# watchdog both consult/set it so a job completes exactly once even when its EOF
# and an abort race. A retry is a NEW (job_id, job_try) pair, so it is never
# blocked by the prior try's entry.
sub _decided_key { my ($self, $job_id, $job_try) = @_; return join('+', $job_id // '', $job_try // 0) }

sub job_already_decided {
    my $self = shift;
    my ($job_id, $job_try) = @_;
    return $self->{'decided_jobs'}{$self->_decided_key($job_id, $job_try)} ? 1 : 0;
}

sub mark_job_decided {
    my $self = shift;
    my ($job_id, $job_try) = @_;
    $self->{'decided_jobs'}{$self->_decided_key($job_id, $job_try)} = 1;
    return;
}

# Act on one collector's captured verdict (ARCHITECTURE.md §5.4):
#   final_state seen + halt  -> bail (already fired when the halt transition
#                               arrived; never retry a bailing job).
#   final_state seen + pass  -> complete (stop the task; 'done').
#   final_state seen + !pass -> retry if the task has tries left, else fail.
#   final_state ABSENT       -> fail. If the runner deliberately terminated this
#                               job (a bail/abort terminate) record it 'aborted';
#                               otherwise flag a possible harness/collector
#                               internal error. Never a false pass.
sub decide_collector_outcome {
    my $self = shift;
    my ($entry) = @_;

    my $job_id = $entry->{job_id};
    my $fs     = $entry->{final_state};

    # halt wins over retry: a bailing job is completed (failed), never re-queued.
    if ($entry->{halt} || ($fs && defined($fs->{halt}) && length($fs->{halt}))) {
        $self->_collector_stop($job_id);
        $self->announce_job($job_id, 'done', run_id => $entry->{run_id});
        return;
    }

    # No verdict at EOF: fail. A deliberately terminated job (a bail/abort) is
    # recorded as aborted; otherwise the missing final state is itself a collector
    # problem and the reason flags it as possibly-not-the-test.
    unless ($fs) {
        my $reason = $entry->{terminated}
            ? ($entry->{terminate_reason} // "Job terminated by the runner")
            : "The collector exited without reporting a final state; this may be a harness/collector problem and not a fault in the test itself";
        $self->_collector_no_verdict($entry, $reason);
        return;
    }

    if ($fs->{pass}) {
        # Record that THIS job reported a pass, so a later non-zero health exit on
        # reap (a post-pass collector failure, A3) flags the suite -- the test
        # itself stays green and is never reopened (ARCHITECTURE.md §5.4).
        $self->{'job_passed'}{$job_id} = $entry->{run_id} // '';
        $self->_collector_stop($job_id);
        $self->announce_job($job_id, 'done', run_id => $entry->{run_id});
        return;
    }

    # Audited failure: retry if tries remain (re-queue same job_id, new job_try),
    # else complete (fail). The retry POLICY lives in the task (--retry +
    # # HARNESS-retry / # HARNESS-no-retry directives, parsed into task->{retry}).
    if ($self->_collector_retry_if_tries($entry)) {
        $self->announce_job($job_id, 'retry', run_id => $entry->{run_id});
        return;
    }

    $self->_collector_stop($job_id);
    $self->announce_job($job_id, 'done', run_id => $entry->{run_id});

    return;
}

# Stop a task in canonical state, best-effort (a racing stop/abort may already
# have cleared it -- not an error here).
sub _collector_stop {
    my $self = shift;
    my ($job_id) = @_;
    return unless defined $job_id;
    eval { $self->state->stop_task($job_id); 1 };
    return;
}

# Retry the task if it has tries left: consult the task's retry directive against
# its current try and, when a try remains, re-queue the same job_id with an
# incremented job_try (State::retry_task) and advance the current-try marker so
# the superseded connection's late EOF becomes a no-op. Returns true when it
# retried. A halted run never retries (State::retry_task itself guards this).
sub _collector_retry_if_tries {
    my $self = shift;
    my ($entry) = @_;

    my $job_id = $entry->{job_id} // return 0;
    my $try    = $entry->{job_try};

    my $running = $self->state->running_tasks // {};
    my $task    = $running->{$job_id} or return 0;

    my $retries = $self->_job_retry_count($task, $entry->{run_id});
    return 0 unless defined($try) && $try < $retries;

    my $ok = eval { $self->state->retry_task($job_id); 1 };
    return 0 unless $ok;

    # The re-queued attempt is try+1; mark it current so this attempt's connection
    # (which is about to be forgotten) cannot stop/retry the new one.
    $self->{'collector_current_try'}{$job_id} = $try + 1;

    return 1;
}

# How many retries the job is allowed: the per-file `# HARNESS-retry N`/-no-retry
# directive lands on the task ($task->{retry}); the run-level --retry lives on the
# Run. Mirror Test2::Harness2::Runner::Job::retry's task-then-run fallback so the
# EOF decision matches what the old reap-driven decision did.
sub _job_retry_count {
    my $self = shift;
    my ($task, $run_id) = @_;

    return $task->{retry} if defined $task->{retry};

    my $run = $self->state->run;
    return $run->retry // 0 if $run && (!defined($run_id) || $run->run_id eq $run_id);

    return 0;
}

# No-verdict render mutation (A6, ARCHITECTURE.md §5.4): a completion the runner
# decided with NO collector final_state (EOF-no-verdict, or a terminated/aborted
# job) has no usable completed/final_state transition for the renderer, so emit a
# runner-originated terminal 'aborted' harness_runner_job mutation carrying the
# reason. The subscriber (the command-side renderer driver) folds it exactly once
# and rolls the job up as a failed completion, the reason shown as harness output
# (distinct from job output). Both the terminated/aborted and the EOF-no-verdict
# cases render this way; only the reason text distinguishes them to the reader.
sub _collector_no_verdict {
    my $self = shift;
    my ($entry, $reason) = @_;

    my $job_id = $entry->{job_id} // return;

    $self->_collector_stop($job_id);

    $self->announce_job(
        $job_id, 'aborted',
        run_id  => $entry->{run_id},
        details => $reason,
    );

    return;
}

# A bail-out (the early halt transition) for a run. Stop dispatching new jobs for
# the run, and -- with --abort-on-bail (default) -- tear the run down through the
# shared abort-intent primitive (terminate_run_collectors): record an abort INTENT
# for the run and send the terminate control to every live test collector of the
# run. Each terminated collector kills its child and exits -> EOF, decided as
# aborted (never a false pass). A job dispatched but not yet connected gets the
# terminate on connect (service_identified consults the intent). halt wins over
# retry: the bailing job's own collector is not re-queued (decide_collector_outcome
# treats a halted entry as a failed completion). With --no-abort-on-bail the runner
# does NOT propagate -- only the bailing test is affected (its collector still
# killed its own child).
sub collector_bail {
    my $self = shift;
    my ($entry, $reason) = @_;

    my $run_id = $entry->{run_id};

    print "$$ $0 BAIL-OUT detected: $reason\n";

    # Stop dispatching new jobs for this run either way (the run is bailing).
    eval { $self->state->halt_run($run_id); 1 } if defined $run_id;

    return unless $self->settings->runner->abort_on_bail;

    print "$$ $0 Aborting the test run...\n";

    return unless defined $run_id;

    # The bailing collector tears its OWN child down (it emitted the halt); only the
    # other run collectors need the terminate message, so skip its entry.
    $self->terminate_run_collectors($run_id, $reason, skip => $entry);

    return;
}

# The shared bail/abort teardown primitive (ARCHITECTURE.md §5.4 "Bail and
# abort"). Record an abort INTENT for the run -- with a hard-kill deadline -- so a
# collector that connects AFTER this (a job dispatched but not yet connected, B4)
# is terminated on connect (service_identified consults the intent), and send the
# terminate control to every test collector of the run that is already live. Each
# terminated collector kills its child and exits -> EOF, decided as aborted (never
# a false pass). The intent is dropped when the run ends (announce_run). The
# optional `skip` entry (the bailing collector, which tears its own child down) is
# not messaged.
sub terminate_run_collectors {
    my $self = shift;
    my ($run_id, $reason, %params) = @_;

    return unless defined $run_id;

    my $skip = $params{skip};

    # Record (or refresh) the intent. The deadline arms the per-tick hard-kill
    # fallback (_enforce_terminate_grace) for any collector that does not comply.
    my $intent = $self->{'aborting_runs'}{$run_id} //= {reason => $reason};
    $intent->{deadline} //= time + $self->_terminate_grace;

    for my $key (keys %{$self->{'collector_conns'} // {}}) {
        my $other = $self->{'collector_conns'}{$key};
        next unless defined($other->{run_id}) && $other->{run_id} eq $run_id;
        next if $skip && $other == $skip;
        $self->_terminate_collector($other, $reason);
    }

    return;
}

# The grace period (seconds) a terminated collector is given to comply (kill its
# child and EOF) before the runner hard-kills its process group (kill(-pid)).
sub _terminate_grace { 10 }

# Send the terminate control to one collector (the bail/abort teardown primitive).
# Mark the entry terminated so its EOF is decided as 'aborted', not a possible
# harness-internal error, and stamp when it was messaged so the per-tick fallback
# can hard-kill it if it does not comply. The collector kills its child and exits
# -> EOF. If the connection is already gone the send is a no-op (the EOF will still
# decide it).
sub _terminate_collector {
    my $self = shift;
    my ($entry, $reason) = @_;

    $entry->{terminated}       //= 1;
    $entry->{terminate_reason} //= $reason;
    $entry->{terminate_sent}   //= time;

    my $conn = $entry->{conn} or return;
    return if $conn->closed;

    eval { $conn->send_control('terminate', reason => $reason); 1 };

    return;
}

# Per-tick hard-kill fallback (ARCHITECTURE.md §5.4: "Pid/process-group is the
# fallback only"). A collector that was sent a terminate but has not EOFed within
# the grace is hard-killed via its process group (kill(-pid)) -- a detached
# collector setsids (so its pid leads its group) and a non-detached collector is the
# runner's own child. The pid comes from the handshake (entry->{pid}); the fire-once
# ledger still guards the eventual EOF so this never double-decides. Best-effort: a
# missing pid or a vanished group is a no-op.
sub _enforce_terminate_grace {
    my $self = shift;

    my $aborting = $self->{'aborting_runs'} or return;
    return unless keys %$aborting;

    my $now   = time;
    my $conns = $self->{'collector_conns'} // {};

    for my $key (keys %$conns) {
        my $entry = $conns->{$key};
        next unless $entry->{terminate_sent};
        next if $entry->{hard_killed};

        my $intent = $aborting->{$entry->{run_id} // ''} or next;
        next unless defined($intent->{deadline}) && $now >= $intent->{deadline};

        my $conn = $entry->{conn};
        next if $conn && $conn->closed;    # already gone; its EOF will decide it

        my $pid = $entry->{pid} or next;
        $entry->{hard_killed} = 1;
        eval { kill('KILL', -$pid) || kill('KILL', $pid); 1 };
    }

    return;
}

# The --collector-connect-timeout, in seconds (0 = off). The mandatory reporter
# (ARCHITECTURE.md §5.4) means a dispatched/running job whose collector never
# connects would never EOF -> hang; this bounds that wait. Read from settings;
# a unit harness with no runner group falls back to off.
sub _collector_connect_timeout {
    my $self = shift;

    my $settings = $self->settings or return 0;
    return 0 unless $settings->check_group('runner');
    return $settings->runner->collector_connect_timeout // 0;
}

# Per-tick scan (ARCHITECTURE.md §5.4 "The reporter is mandatory"): a job the
# runner marked dispatched/running whose collector never connected within
# --collector-connect-timeout is failed/aborted -- it would otherwise never EOF and
# hang the run. Mirrors the #33 _expire_stale_stages per-tick shape. The job is
# synthesized as aborted (the no-verdict render mutation) and marked decided in the
# shared fire-once ledger so a collector that connects after this is a no-op (and is
# also terminated, since the failed mutation cleared its watch but the job is gone).
sub _enforce_collector_connect_timeout {
    my $self = shift;

    my $timeout = $self->_collector_connect_timeout or return;

    my $watch = $self->{'job_connect_watch'} or return;
    return unless keys %$watch;

    my $now     = time;
    my $running = $self->state->running_tasks // {};

    for my $job_id (keys %$watch) {
        my $info = $watch->{$job_id};
        next unless $now - $info->{since} > $timeout;

        # Only act while the job is still tracked running; a racing completion
        # already cleared it. Drop the watch either way.
        delete $watch->{$job_id};
        my $task = $running->{$job_id} or next;

        my $job_try = $task->{is_try};
        next if $self->job_already_decided($job_id, $job_try);
        $self->mark_job_decided($job_id, $job_try);
        delete $self->{'collector_current_try'}{$job_id};

        $self->_collector_no_verdict(
            {job_id => $job_id, run_id => $task->{run_id}, terminated => 1},
            "The test collector did not connect within ${timeout}s; failing the job (it can never report completion)",
        );
    }

    return;
}

# Record an abort INTENT for a run and terminate its collectors (the abort path:
# `yath abort` and owner-disconnect abort, B3 / B4). Same primitive as a bail; the
# distinct entry point lets the watchdog and the truncate handler tear a run down
# without a halt transition. Returns the number of live run collectors it messaged.
sub abort_run_collectors {
    my $self = shift;
    my ($run_id, $reason) = @_;

    return 0 unless defined $run_id;

    $self->terminate_run_collectors($run_id, $reason);

    my $count = 0;
    for my $key (keys %{$self->{'collector_conns'} // {}}) {
        my $other = $self->{'collector_conns'}{$key};
        $count++ if defined($other->{run_id}) && $other->{run_id} eq $run_id;
    }

    return $count;
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
    $self->submit_action('queue_task', $payload->{task});
    return undef;
}

sub request_handler_stop_run {
    my $self = shift;
    my ($payload) = @_;
    $self->submit_action('stop_run', $payload->{run_id});
    return undef;
}

# `yath spawn` submits its spawn over runner.socket. The runner folds it into
# the canonical State, which the (persistent) stages pick up to launch the script.
#
# Review P2: this is acknowledged (two-way). The command then blocks on a worker
# tempfile (the legitimate wait while the spawned program runs) whose own timeout
# is long; if the runner cannot route the spawn -- it is not the state hub, or the
# target stage does not exist / is not a live ready preload service -- the command
# would otherwise learn nothing until that long wait expired. So we resolve the
# spawn's stage and check stage readiness synchronously and return a negative ack
# in that case, letting `yath spawn` fail promptly with a clear diagnostic. On a
# live stage we queue the spawn and ack success; the stage launches it and the
# tempfile wait proceeds as the legitimate run of the spawned program.
sub request_handler_queue_spawn {
    my $self = shift;
    my ($payload) = @_;

    return {ok => 0, error => 'not the runner state hub'}
        unless $self->{'rootpid'} == $$;

    my $spawn = $payload->{spawn} // {};
    my ($stage, $ready) = $self->state->spawn_stage_ready($spawn);

    return {ok => 0, stage => $stage, error => "No live preload stage '$stage' is available to run the spawn"}
        unless $ready;

    $self->state->queue_spawn($spawn);

    return {ok => 1, queued => 1, stage => $stage};
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
    $self->state->enqueue_task($payload->{task}, $payload->{run});
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
        job_pids   => $self->{'job_pids'},
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
        job_pids => $self->{'job_pids'},
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

    $self->{'job_pids'}->{$job_id} = $pid;

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

    delete $self->{'job_pids'}->{$job_id};

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

    my $current = $self->{service_peers}{"preload-$stage"};

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

# The runner is the hub of the transition channel. Every non-runner
# collector (each test job, each transient preload stage, any aux collector)
# connects its reporter to runner.socket and streams its transitions here; the
# runner folds them into this canonical in-process state object (uuid, name,
# category, events_file, try, run_uuid, status, failing/diagnosing, final_state,
# plus drain-on-call change-lists). The runner's OWN collector (the one
# App::Yath2::Command::test::start_runner wraps it in) does NOT report here -- it
# records to its own events file only; the runner is the hub, not its own peer.
sub monitor {
    my $self = shift;
    return $self->{'monitor'} //= Test2::Harness2::Runner::Monitor->new;
}

# Role::Service hands every transition frame here (one-way, no reply).
# Only the root runner process is the transition hub; a forked stage service does
# not fold transitions (it dispatches/reaps jobs and reports outcomes back to the
# root over runner.socket). Fold the already-decoded payload into the monitor.
sub service_transition {
    my $self = shift;
    my ($payload, $frame, $conn) = @_;

    return unless $self->{'rootpid'} == $$;

    $self->monitor->feed($payload);

    # Capture a test collector's verdict ON ITS CONNECTION so the EOF decision
    # keys off the connection, not the collector uuid (ARCHITECTURE.md §5.4). A
    # final_state rides the harness_final_state facet; a bail rides the early
    # harness_state_transition state => 'halt'. Both are recorded on the conn -> job
    # entry; the halt also triggers the run bail before the connection EOFs.
    if ($conn && $self->{'collector_conns'} && (my $entry = $self->{'collector_conns'}{"$conn"})) {
        my $fd = ref($payload) eq 'HASH' ? $payload->{facet_data} : undef;
        if (ref($fd) eq 'HASH') {
            $entry->{final_state} = $fd->{harness_final_state}
                if $fd->{harness_final_state};

            my $st = $fd->{harness_state_transition};
            if ($st && ($st->{state} // '') eq 'halt') {
                my $reason = $st->{details} // 'bail-out';
                $entry->{halt} //= $reason;
                $self->collector_bail($entry, $reason);
            }
        }
    }

    # Forward every state-mutating transition to subscribed clients so
    # their snapshot-plus-transitions mirror stays whole (ARCH 4.2-4.3). The frame
    # is forwarded verbatim (no recompress) -- it is already a self-contained zstd
    # frame the subscriber's mirror folds the same way this monitor just did.
    #
    # Route per-run. Resolve the frame's run association (the
    # collector run_uuid, == the run's run_id) AFTER feeding the monitor, so a
    # later transition carrying only the uuid resolves against the tracked
    # collector. A run-less frame (the runner's own, a preload-stage lifecycle
    # transition) routes to every subscriber.
    $self->forward_frame($frame, $self->monitor->run_for_payload($payload))
        if $frame;

    return;
}

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

    $self->add_subscriber($conn, $run_id) if defined $conn;

    return {ok => 1, snapshot => $self->monitor->snapshot($run_id)};
}

# The runner ORIGINATES some state mutations itself -- it dispatches a
# job to a stage, forks a job (running), and reaps a job (done). ARCH 4.2 is
# explicit these must reach subscribers too, not only the folded collector
# transitions, so the snapshot-plus-transitions contract stays whole. We express
# one as a harness_runner_job facet on the collector wire form, fold it into our
# own monitor (so a later snapshot includes it) and forward the same frame to
# subscribers (so their mirror folds it identically).
sub announce_job {
    my $self = shift;
    my ($job_id, $state, %extra) = @_;

    return unless $self->{'rootpid'} == $$;
    return unless defined $job_id;

    # Connect-timeout tracking (ARCHITECTURE.md §5.4 "The reporter is mandatory").
    # The moment the runner first marks a job dispatched/running, stamp when it is
    # owed a collector connection; if no collector connects (service_identified)
    # within --collector-connect-timeout the per-tick scan fails the job (it would
    # otherwise never EOF and hang the run). A terminal mutation clears the stamp.
    if ($state eq 'dispatched' || $state eq 'running') {
        $self->{'job_connect_watch'}{$job_id} //= {since => time, run_id => $extra{run_id}};
    }
    elsif ($state eq 'done' || $state eq 'aborted' || $state eq 'requeued') {
        delete $self->{'job_connect_watch'}{$job_id};
    }

    my $rj = {job_id => $job_id, state => $state, %extra};

    # Route this runner-originated mutation to its run's subscribers.
    # 'dispatched'/'running'/'retry'/'done' from the scheduler carry run_id in
    # %extra; a stage-reported 'done'/'retry' (from the stop_task/retry_task
    # request handlers) does not, so backfill it from the run_id the monitor
    # already tracked for the job at dispatch.
    if (!defined $rj->{run_id}) {
        my $known = $self->monitor->job($job_id);
        $rj->{run_id} = $known->{run_id} if $known && defined $known->{run_id};
    }

    my $payload = {facet_data => {harness_runner_job => $rj}};

    $self->monitor->feed($payload);

    my $frame = compress_blob(encode_json($payload));
    $self->forward_frame($frame, $rj->{run_id});

    return;
}

# Post-pass collector failure (A3, ARCHITECTURE.md §5.4). The runner reaped a test
# collector and saw a NON-ZERO health exit even though that collector had already
# reported harness_final_state.pass=1. The test stays GREEN (its audited verdict
# already succeeded and is never reopened), but the collector itself malfunctioned
# afterward, so report the error to HARNESS output and flag the SUITE failed: the
# runner originates a harness_run_health mutation the renderer folds so
# `yath test`/`run` exits non-zero even though every test passed. This is the ONLY
# place a collector's exit code is consulted -- post-hoc, suite-level, never a
# per-test verdict. Folded into our own monitor (so a later snapshot carries it)
# and forwarded to the run's subscribers.
sub announce_run_health {
    my $self = shift;
    my ($run_id, $reason) = @_;

    return unless $self->{'rootpid'} == $$;

    # Harness output (distinct from job output) so the collector bug is visible.
    print STDERR "yath: $reason\n";

    my $rh = {run_id => $run_id, reason => $reason, stamp => time};
    my $payload = {facet_data => {harness_run_health => $rh}};

    $self->monitor->feed($payload);

    my $frame = compress_blob(encode_json($payload));
    $self->forward_frame($frame, $run_id);

    return;
}

# The runner originates a run-completion mutation. The persistent
# runner serves many runs and keeps its socket open, so a run-scoped subscriber
# (the `yath run` command) cannot key completion on the socket closing the way the
# transient `yath test` command does. Instead the runner announces each run's end
# over the socket -- folded into its own monitor (so a later snapshot carries it)
# and forwarded to that run's subscribers -- when the run leaves the active slot.
sub announce_run {
    my $self = shift;
    my ($run_id) = @_;

    return unless $self->{'rootpid'} == $$;
    return unless defined $run_id;
    return if $self->{'announced_runs'}->{$run_id}++;

    # The run is over: drop its bail/abort intent so a persistent runner does not
    # carry it into a future run that reuses nothing of it (the per-job decision
    # maps are dropped on each job's EOF; this is the one run-scoped map).
    delete $self->{'aborting_runs'}{$run_id} if $self->{'aborting_runs'};

    my $payload = {facet_data => {harness_run_end => {run_id => $run_id, stamp => time}}};

    $self->monitor->feed($payload);

    my $frame = compress_blob(encode_json($payload));
    $self->forward_frame($frame, $run_id);

    # Ticket #12 / ARCHITECTURE.md §4.2: a finished run is retained (queryable) only
    # while its owner connection is live. A run with NO owner record -- e.g. one queued
    # by an internal/non-socket path -- can never be queried, so purge it the moment it
    # completes rather than retaining it forever. A run whose owner is still connected
    # stays retained until that owner drops (service_conn_closed purges it then).
    $self->state->purge_run($run_id)
        unless $self->{'run_owners'} && $self->{'run_owners'}->{$run_id};

    return;
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
