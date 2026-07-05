package Test2::Harness2::Runner::Role::Service::TransitionHub;
use v5.38;

our $VERSION = '2.000000';

use Time::HiRes qw/time/;
use Test2::Harness2::Util qw/mono_time/;

use Test2::Collector::Util::Zstd qw/compress_blob/;
use Test2::Harness2::Util::JSON qw/encode_json/;

use Test2::Harness2::Runner::Monitor();

use Role::Tiny;

# Constant-only slots (TODO-17 pattern): grep/typo safety on the runner-hash keys this
# role touches. monitor is the lazily-built Monitor mirror declared here; job_passed
# and collector_reap are shared with Completion. Role::Tiny does not share HashBase
# constants across a composition, so each role declares its own copy.
use Test2::Harness2::Util::HashBase qw{
    +monitor
    +job_passed
    +collector_reap
};

requires qw/state settings/;

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::Role::Service::TransitionHub - The runner's transition
hub + announce forwarding.

=head1 DESCRIPTION

This role carries the transition-channel half of L<Test2::Harness2::Runner>: the
canonical L<Test2::Harness2::Runner::Monitor> fold, the C<service_transition> hub
that folds every collector transition frame into the monitor and forwards it to
subscribers, and the C<announce_*> family that folds and forwards
runner-originated mutations (job dispatched/running/retry/done, run completion,
run health, system load) so a subscriber's mirror folds them identically.

It is composed into the runner alongside
L<Test2::Harness2::Runner::Role::Service::Handlers>,
L<Test2::Harness2::Runner::Role::Service::Completion>,
L<Test2::Harness2::Role::Service> and
L<Test2::Harness2::Runner::Role::Scheduler>; every method here is a method on the
runner C<$self> and shares its hashref slots and its other composed methods
(C<state>, C<forward_frame>, C<add_subscriber>).

=head1 SYNOPSIS

    package Test2::Harness2::Runner;
    use Role::Tiny::With;
    with 'Test2::Harness2::Runner::Role::Service::TransitionHub';

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

=item $self->announce_system_load($load)

Fold and forward (globally) a system-load snapshot reported by the sampler service,
so it is logged and reaches every subscriber.

=item $self->announce_run_health($run_id, $reason)

Report a post-pass collector failure: the runner reaped a collector with a
non-zero health exit after it had already reported a pass. The test stays green;
this flags the suite failed (a C<harness_run_health> mutation) so the command
exits non-zero, and prints the error to harness output.

=back

=cut

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
    # track_pending => 0 (TODO-135 finding 3): the hub only feeds + snapshots; the
    # PENDING_* drain-on-call lists are consumed exclusively by subscriber-side mirrors
    # (Renderer::Driver / Renderer::Base), never here, and snapshot/apply_snapshot never
    # carry them -- so populating them hub-side is unbounded dead weight.
    return $self->{+MONITOR} //= Test2::Harness2::Runner::Monitor->new(track_pending => 0);
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

# Shared fold+encode+forward tail of the announce_* family: wrap the facets in the
# collector wire form, fold it into our own monitor (so a later snapshot carries it),
# then encode a fresh self-contained frame and forward it. $run_id routes it to that
# run's subscribers; undef broadcasts globally (announce_system_load). service_transition
# stays OUT of this helper: it forwards the ALREADY-received frame verbatim, without
# re-encoding.
sub _announce {
    my ($self, $facets, $run_id) = @_;

    my $payload = {facet_data => $facets};

    $self->monitor->feed($payload);

    my $frame = compress_blob(encode_json($payload));
    $self->forward_frame($frame, $run_id);

    return;
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
        # 'since' is read ONLY by _enforce_collector_connect_timeout's interval
        # math -- never reported or persisted -- so it is monotonic and pairs with
        # the mono_time there. (TODO-134 finding 104)
        $self->{'job_connect_watch'}{$job_id} //= {since => mono_time, run_id => $extra{run_id}};
    }
    elsif ($state eq 'done' || $state eq 'aborted' || $state eq 'requeued') {
        delete $self->{'job_connect_watch'}{$job_id};
    }

    my $rj = {job_id => $job_id, state => $state, %extra};

    # Route this runner-originated mutation to its run's subscribers. Every caller
    # passes a run_id, but its VALUE can be undef: an EOF-decided collector whose
    # identity handshake omitted run_id leaves the conn entry's run_id undef (see
    # service_identified), so the Completion 'done'/'retry'/'aborted' announces
    # forward that undef. Backfill it from the run_id the monitor already tracked
    # for the job at dispatch.
    if (!defined $rj->{run_id}) {
        my $known = $self->monitor->job($job_id);
        $rj->{run_id} = $known->{run_id} if $known && defined $known->{run_id};
    }

    $self->_announce({harness_runner_job => $rj}, $rj->{run_id});

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

    $self->_announce({harness_run_health => $rh}, $run_id);

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

    # Drop any per-job connect-timeout termination intents for this run: a collector
    # that still never connected has nothing left to tear down once the run ends.
    if (my $tj = $self->{'terminated_jobs'}) {
        delete $tj->{$_} for grep { ($tj->{$_}{run_id} // '') eq $run_id } keys %$tj;
    }

    # Bound the post-pass reap map (ticket TODO-28 C2): a detached collector that is never
    # reaped (e.g. on a platform without subreaper support, an accepted loss) would
    # otherwise leak its entry on a persistent runner. Drop this run's entries at run
    # end; a still-pending reap on a supported platform has already fired by now.
    if (my $cr = $self->{+COLLECTOR_REAP}) {
        delete $cr->{$_} for grep { ($cr->{$_}{run_id} // '') eq $run_id } keys %$cr;
    }

    $self->_announce({harness_run_end => {run_id => $run_id, stamp => time}}, $run_id);

    # (TODO-135 finding 3) The run is retired and its end frame forwarded: prune all
    # O(tests) hub-monitor state for it. Existing run subscribers already received the
    # forwarded run_end; a late/reconnecting run-scoped subscriber keys completion on
    # the retained RUNS marker (kept below) -> run_done fires instead of hanging.
    # Capture the run's job_ids BEFORE pruning (monitor jobs for the run, unioned with
    # job_passed keys whose value is the run) so the deferred, live-safe ledger sweep
    # can retire their fire-once / current-try / pass ledgers once every collector
    # connection has closed and any post-retirement reap has fired.
    my %job_ids;
    for my $job_id ($self->monitor->job_ids) {
        my $j = $self->monitor->job($job_id) or next;
        $job_ids{$job_id} = 1 if defined($j->{run_id}) && $j->{run_id} eq $run_id;
    }
    if (my $jp = $self->{+JOB_PASSED}) {
        $job_ids{$_} = 1 for grep { ($jp->{$_} // '') eq $run_id } keys %$jp;
    }

    $self->monitor->prune_run($run_id);

    # 'since' is interval math read only by _flush_run_ledger_sweeps -- monotonic,
    # pairs with the mono_time there (TODO-134 finding 104).
    push @{$self->{'ledger_sweep'}} => {run_id => $run_id, job_ids => [keys %job_ids], since => mono_time};

    # Retain ONLY the O(1)-per-run end marker (the monitor RUNS entry + the
    # announced_runs key) in a bounded FIFO ring, so a late/reconnecting run-scoped
    # subscriber of any RECENT run still sees run_done. Older markers age out (their
    # re-prune also catches any straggler collector/job/health recreated since).
    push @{$self->{'announced_ring'}} => $run_id;
    while (@{$self->{'announced_ring'}} > $self->_run_marker_retention) {
        my $old = shift @{$self->{'announced_ring'}};
        delete $self->{'announced_runs'}{$old};
        $self->monitor->drop_run_marker($old);
    }

    # Opportunistic sweep (also driven once per scheduler_tick): retire any now-eligible
    # ledger entries whose grace has elapsed and whose collector connections have closed.
    $self->_flush_run_ledger_sweeps;

    # Ticket TODO-12 / ARCHITECTURE.md §4.2: a finished run is retained (queryable) only
    # while its owner connection is live. A run with NO owner record -- e.g. one queued
    # by an internal/non-socket path -- can never be queried, so purge it the moment it
    # completes rather than retaining it forever. A run whose owner is still connected
    # stays retained until that owner drops (service_conn_closed purges it then).
    $self->state->purge_run($run_id)
        unless $self->{'run_owners'} && $self->{'run_owners'}->{$run_id};

    return;
}

# The number of retired-run end markers retained for a late/reconnecting run-scoped
# subscriber of a recent run (TODO-135 finding 3). OWNER-OVERRIDABLE: raising it trades a
# few hundred bytes/run for a longer late-subscribe window; 0 restores "hang on late
# subscribe to a finished run".
sub _run_marker_retention { 100 }

# The grace (seconds) a retired run's job ledgers are held before sweeping, so a
# post-retirement reap (job_passed -> A3) or a straggler EOF has fired first (TODO-135
# finding 3). Reuses the terminate-grace family of intervals.
sub _ledger_sweep_grace { 30 }

# Deferred, live-connection-safe sweep of retired runs' per-job ledgers (TODO-135
# finding 3). Called from announce_run and once per scheduler_tick. Immediate deletion
# at retirement is UNSAFE two ways: (i) a watchdog-aborted job's collector connection
# can still be OPEN at retirement, and its later EOF -- with decided_jobs already gone
# -- would pass the fire-once check and RE-DECIDE the job (a double 'aborted' announce);
# (ii) a WATCHED collector's process may be reaped AFTER retirement, when
# _check_post_pass_health still needs job_passed for the A3 escalation. So a job is
# swept only once its collector connection has CLOSED and a grace has elapsed since the
# run retired -- deferring exactly the two hazard windows while keeping the ledgers
# bounded on a persistent runner.
sub _flush_run_ledger_sweeps {
    my $self = shift;

    my $queue = $self->{'ledger_sweep'} or return;
    return unless @$queue;

    my $now   = mono_time;    # pairs with the 'since' stamp in announce_run (TODO-134 finding 104)
    my $grace = $self->_ledger_sweep_grace;
    my $conns = $self->{'collector_conns'} // {};

    # Job ids that still carry a LIVE (non-closed) collector connection: defer them.
    my %live;
    for my $key (keys %$conns) {
        my $entry = $conns->{$key};
        my $jid   = $entry->{job_id} // next;
        my $conn  = $entry->{conn};
        $live{$jid} = 1 unless $conn && $conn->closed;
    }

    my @keep;
    for my $item (@$queue) {
        my $run_id = $item->{run_id};
        my $aged   = ($now - $item->{since}) >= $grace;

        my @pending;
        for my $job_id (@{$item->{job_ids} // []}) {
            if (!$aged || $live{$job_id}) {
                push @pending => $job_id;    # keep queued: grace not elapsed, or conn still open
                next;
            }

            delete $self->{'decided_jobs'}{$job_id}          if $self->{'decided_jobs'};
            delete $self->{'collector_current_try'}{$job_id} if $self->{'collector_current_try'};
            delete $self->{+JOB_PASSED}{$job_id}
                if $self->{+JOB_PASSED} && ($self->{+JOB_PASSED}{$job_id} // '') eq $run_id;
        }

        $item->{job_ids} = \@pending;
        push @keep => $item if @pending;    # drop the run's queue entry once empty
    }

    @$queue = @keep;

    return;
}

# The system-load sampler service reports a new load snapshot (ARCHITECTURE.md
# §4.4). System load is a global singleton, not run-scoped: fold it into the
# monitor (so a later snapshot carries the latest value) and forward the frame to
# EVERY subscriber (run_id => undef = global / run-less), so the rendered + archived
# run records load over time and a late subscriber gets current load from the
# snapshot. Originated by the runner from request_handler_system_load.
sub announce_system_load {
    my $self = shift;
    my ($load) = @_;

    return unless $self->{'rootpid'} == $$;
    return unless $load;

    # System load is a global singleton (run-less), so broadcast to every subscriber.
    $self->_announce({harness_system => $load}, undef);

    return;
}

1;

__END__

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness2/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
