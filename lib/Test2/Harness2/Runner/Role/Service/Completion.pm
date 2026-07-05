package Test2::Harness2::Runner::Role::Service::Completion;
use v5.38;

our $VERSION = '2.000000';

use Time::HiRes qw/time/;
use Test2::Harness2::Util qw/mono_time/;

use Role::Tiny;

# Constant-only slots (TODO-17 pattern): grep/typo safety on the runner-hash keys this
# role touches. job_passed/collector_reap are first-written here; job_pids is owned
# by the runner. Role::Tiny does not share HashBase constants across a composition,
# so each role declares its own copy.
use Test2::Harness2::Util::HashBase qw{
    +job_passed
    +collector_reap
    +job_pids
};

requires qw/state settings/;

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::Role::Service::Completion - The runner's collector-EOF
completion + terminate/abort machinery.

=head1 DESCRIPTION

This role carries the completion-decision half of L<Test2::Harness2::Runner>: the
methods that decide a test's outcome when its collector connection EOFs
(ARCHITECTURE.md §5.4), the shared fire-once ledger that guarantees exactly one
decision per C<(job_id, job_try)>, the retry policy, and the bail/abort teardown
primitive (record an abort intent + terminate the run's live and late-connecting
test collectors, with a per-tick hard-kill grace fallback and a
collector-connect-timeout scan).

It is composed into the runner alongside
L<Test2::Harness2::Runner::Role::Service::Handlers>,
L<Test2::Harness2::Runner::Role::Service::TransitionHub>,
L<Test2::Harness2::Role::Service> and
L<Test2::Harness2::Runner::Role::Scheduler>; every method here is a method on the
runner C<$self> and shares its hashref slots and its other composed methods
(C<state>, C<settings>, C<announce_job>).

=head1 SYNOPSIS

    package Test2::Harness2::Runner;
    use Role::Tiny::With;
    with 'Test2::Harness2::Runner::Role::Service::Completion';

=head1 PUBLIC METHODS

=over 4

=item $self->collector_conn_eof($conn)

Decide a test's outcome on its collector connection's EOF (drain done): the
verdict was captured on the connection as transitions arrived. Fire-once per
C<(job_id, job_try)>, stale-try guarded.

=item $self->mark_job_decided($job_id, $job_try)

=item $bool = $self->job_already_decided($job_id, $job_try)

The shared fire-once ledger keyed by C<(job_id, job_try)>: the EOF decision and
the watchdog both consult/set it so a job completes exactly once even when its EOF
and an abort race.

=item $self->terminate_run_collectors($run_id, $reason)

=item $self->terminate_run_collectors($run_id, $reason, skip =E<gt> $entry)

The shared bail/abort teardown primitive: record an abort intent for the run (so a
late-connecting collector is terminated on connect) and send the runner-to-collector
terminate control to every live test collector of the run. The optional C<skip>
entry (a collector tearing its own child down) is not messaged.

=item $self->abort_run_collectors($run_id, $reason)

Tear a run down through C<terminate_run_collectors> from the abort path (C<yath
abort> and owner-disconnect abort).

=back

=cut

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

    delete $self->{+JOB_PIDS}->{$job_id} if defined $job_id;

    # Stale try: a superseded attempt's connection was retired on retry; its late
    # EOF must not stop/retry the live try (the current incarnation owns it).
    my $current = $self->{'collector_current_try'}{$job_id};
    return if defined($current) && defined($job_try) && "$current" ne "$job_try";

    # This EOF is for the CURRENT try (the stale-try guard above already returned
    # otherwise), so retire its current-try marker on ANY outcome -- including a
    # suppressed EOF the watchdog already decided, which returns below. Doing this
    # BEFORE the fire-once return fixes a latent leak (TODO-135 finding 2/15): a
    # watchdog-decided first-try job's later EOF previously returned early and left the
    # marker forever on a persistent runner.
    delete $self->{'collector_current_try'}{$job_id};

    # FIRE-ONCE: exactly one completion per (job_id, job_try). The decided set is
    # shared with the watchdog (an abort/owner-disconnect/wind-down abort marks the
    # job decided), so an EOF that arrives after the watchdog already decided this
    # try is a no-op, and vice versa. Per-entry/global both keyed here.
    return if $self->job_already_decided($job_id, $job_try);
    $self->mark_job_decided($job_id, $job_try);

    $self->decide_collector_outcome($entry);

    return;
}

# The shared fire-once ledger, a two-level map decided_jobs{job_id}{job_try} (TODO-135
# finding 2): the EOF decision and the watchdog both consult/set it so a job completes
# exactly once even when its EOF and an abort race. A retry is a NEW (job_id, job_try)
# pair, so it is never blocked by the prior try's entry. The try is normalized `// 1`
# to match the collector handshake (Job.pm sends is_try //= task->{is_try} // 1): the
# watchdog and the connect-timeout pass the raw task->{is_try} (undef on a first
# attempt), the EOF path the wire job_try (1 on a first attempt), so `// 1` collapses
# both to the SAME key -- the undef-vs-1 mismatch that re-decided aborted first tries.
# Two levels also make a per-run prune (TODO-135 finding 3) an O(1) delete of decided_jobs{job_id}.
sub job_already_decided {
    my $self = shift;
    my ($job_id, $job_try) = @_;
    my $tries = $self->{'decided_jobs'}{$job_id // ''} or return 0;
    return $tries->{$job_try // 1} ? 1 : 0;
}

sub mark_job_decided {
    my $self = shift;
    my ($job_id, $job_try) = @_;
    $self->{'decided_jobs'}{$job_id // ''}{$job_try // 1} = 1;
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

    # A collector the runner deliberately terminated (a bail/abort terminate) is
    # recorded 'aborted' -- the runner's terminate is the authoritative outcome,
    # never a retry or an audited failure. This is checked BEFORE the final_state
    # branches because a terminated collector can still flush a failing final_state
    # before it dies (its synthesized exit audits as a failure); without this guard
    # such a sibling would take the audited-failure/retry path -- mis-rendering the
    # abort and, on a halted run, leaving the job in RUNNING (a hang).
    if ($entry->{terminated}) {
        $self->_collector_no_verdict($entry, $entry->{terminate_reason} // "Job terminated by the runner");
        return;
    }

    # halt wins over retry: a bailing job is completed (failed), never re-queued.
    if ($entry->{halt} || ($fs && defined($fs->{halt}) && length($fs->{halt}))) {
        $self->_collector_stop($job_id);
        $self->announce_job($job_id, 'done', run_id => $entry->{run_id});
        return;
    }

    # No verdict at EOF: fail. The missing final state is itself a collector problem;
    # the reason flags it as possibly-not-the-test. (A deliberately terminated job is
    # already handled above, regardless of whether it emitted a final_state.)
    unless ($fs) {
        $self->_collector_no_verdict($entry, "The collector exited without reporting a final state; this may be a harness/collector problem and not a fault in the test itself");
        return;
    }

    if ($fs->{pass}) {
        # Record that THIS job reported a pass, so a later non-zero health exit on
        # reap (a post-pass collector failure, A3) flags the suite -- the test
        # itself stays green and is never reopened (ARCHITECTURE.md §5.4).
        $self->{+JOB_PASSED}{$job_id} = $entry->{run_id} // '';

        # A DETACHED preload collector (ticket TODO-28) is reaped by the runner as an
        # UNWATCHED pid: at reap the runner has only the pid, not the job_id, and
        # job_pids was already cleared by this collector's EOF (collector_conn_eof,
        # the status map). Record a pid-keyed reap entry HERE, at the pass, that
        # survives the EOF so _reaped_unwatched_pid can map the reaped pid back to the
        # job and run A3. Only passes need it (A3 is post-pass). Each collector
        # incarnation has a distinct pid, so it is try-safe; the reap (or the run-end
        # sweep) consumes it. The WATCHED no-preload path does not use this -- its
        # set_proc_exit knows the job_id from the proc's task.
        $self->{+COLLECTOR_REAP}{$entry->{pid}} = {job_id => $job_id, run_id => $entry->{run_id} // ''}
            if defined $entry->{pid};

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
# retried. A halted run DECLINES the re-queue: State::retry_task stops the job but
# returns false, so this returns false too and decide_collector_outcome falls
# through to the done/abort completion path -- the job is a failed completion, not
# a phantom 'retry' left stranded as "never ran" (TODO-117).
sub _collector_retry_if_tries {
    my $self = shift;
    my ($entry) = @_;

    my $job_id = $entry->{job_id} // return 0;
    my $try    = $entry->{job_try};

    my $running = $self->state->running_tasks // {};
    my $task    = $running->{$job_id} or return 0;

    my $retries = $self->_job_retry_count($task, $entry->{run_id});
    # Try ordinals are 1-based (R10 / TODO-49): the first attempt is $try == 1, and the
    # job is allowed $retries retries (so 1 + $retries total attempts). Retry while
    # the current try is within budget: $try <= $retries (equivalently the 0-based
    # attempt index $try - 1 is still < $retries).
    return 0 unless defined($try) && $try <= $retries;

    # TODO-117: retry_task returns a truthy 'actually re-queued' indicator; a halted run
    # declines (stops the job but does NOT re-queue it) and returns false. Treat that
    # decline -- and any die -- as "not retried" so decide_collector_outcome falls
    # through to _collector_stop + announce_job('done') (a failed completion) rather
    # than announcing a 'retry' that never runs.
    my $queued;
    my $ok = eval { $queued = $self->state->retry_task($job_id); 1 };
    return 0 unless $ok && $queued;

    # The re-queued attempt is try+1; mark it current so this attempt's connection
    # (which is about to be forgotten) cannot stop/retry the new one. Skipped on a
    # declined retry (returned above): there is no new attempt to protect (TODO-117 Step 2).
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
    # Interval deadline (compared in _enforce_terminate_grace); monotonic so a
    # wall/NTP step cannot skip or postpone the hard-kill fallback. Pairs with the
    # mono_time in _enforce_terminate_grace. (TODO-134 finding 104)
    $intent->{deadline} //= mono_time + $self->_terminate_grace;

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
    # Per-ENTRY hard-kill deadline (TODO-135 finding 15), the fallback _terminate_collector's
    # comment above promises: a collector terminated via a per-job connect-timeout intent
    # (no run-level aborting_runs record) is still hard-killed if it does not comply.
    # Monotonic to match _enforce_terminate_grace's clock (TODO-134 finding 104); reuses the
    # same _terminate_grace as the run-level intent (identical semantics).
    $entry->{terminate_deadline} //= mono_time + $self->_terminate_grace;

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

    # No early-out on aborting_runs (TODO-135 finding 15): a per-job connect-timeout
    # terminate has NO run-level intent, so it must still be enforceable via its
    # per-entry deadline. The per-entry `next unless terminate_sent` below keeps the
    # idle-tick cost trivial.
    my $aborting = $self->{'aborting_runs'} // {};

    my $now   = mono_time;    # pairs with the deadline armed in terminate_run_collectors + _terminate_collector (TODO-134 finding 104)
    my $conns = $self->{'collector_conns'} // {};

    for my $key (keys %$conns) {
        my $entry = $conns->{$key};
        next unless $entry->{terminate_sent};
        next if $entry->{hard_killed};

        # Intent-first fallback: the run-level abort deadline wins when present (so
        # run-level behavior is byte-identical), otherwise the per-entry deadline
        # (TODO-135 finding 15) governs the per-job connect-timeout terminate.
        my $intent = $aborting->{$entry->{run_id} // ''};
        my $deadline = ($intent && defined $intent->{deadline}) ? $intent->{deadline} : $entry->{terminate_deadline};
        next unless defined($deadline) && $now >= $deadline;

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
# hang the run. Mirrors the TODO-33 _expire_stale_stages per-tick shape. The job is
# synthesized as aborted (the no-verdict render mutation) and marked decided in the
# shared fire-once ledger so a collector that connects after this is a no-op. A
# per-job termination intent (terminated_jobs) is also recorded so such a late
# collector is torn down on connect (service_identified) rather than running its
# test child on as an orphan after its slot was reclaimed.
sub _enforce_collector_connect_timeout {
    my $self = shift;

    my $timeout = $self->_collector_connect_timeout or return;

    my $watch = $self->{'job_connect_watch'} or return;
    return unless keys %$watch;

    my $now     = mono_time;    # elapsed-since-dispatch interval; pairs with the 'since' writer (TODO-134 finding 104)
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

        my $reason = "The test collector did not connect within ${timeout}s; failing the job (it can never report completion)";
        $self->_collector_no_verdict(
            {job_id => $job_id, run_id => $task->{run_id}, terminated => 1},
            $reason,
        );

        # Per-job (NOT run-scoped: the run continues with its other jobs)
        # termination intent so a collector that connects after this timeout -- its
        # slot already reclaimed -- is torn down on connect (service_identified)
        # rather than orphaning its test child. Matched on the try so a legitimate
        # retry's collector is unaffected; swept at run end (announce_run).
        $self->{'terminated_jobs'}{$job_id} = {job_try => $job_try, run_id => $task->{run_id}, reason => $reason};
    }

    return;
}

# Record an abort INTENT for a run and terminate its collectors (the abort path:
# `yath abort` and owner-disconnect abort, B3 / B4). Same primitive as a bail; the
# distinct entry point lets the watchdog and the truncate handler tear a run down
# without a halt transition.
sub abort_run_collectors {
    my $self = shift;
    my ($run_id, $reason) = @_;

    return unless defined $run_id;

    $self->terminate_run_collectors($run_id, $reason);

    return;
}

1;

__END__

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness2/>.

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
