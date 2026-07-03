package Test2::Harness2::Runner::Monitor;
use v5.38;

our $VERSION = '2.000000';

use Object::HashBase qw{
    +collectors
    +jobs
    +runs
    +run_health
    +system_load
    <track_pending
    +pending_new
    +pending_failing
    +pending_diagnosing
    +pending_completed
    +pending_exits
    +pending_finalized
    +pending_aborted
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::Monitor - Fold collector transition messages into the
runner's canonical in-process state.

=head1 DESCRIPTION

The runner is the hub of the transition channel: every collector except the
runner's own connects its reporter to C<runner.socket> and streams the small
high-value set of transition messages -- C<harness_collector> (start),
C<harness_state_transition>, C<harness_final_state>, and
C<harness_collector_finalized>. This monitor folds those messages into
per-collector state, keyed on the collector C<uuid> that rides on every message
(see L<Test2::Collector>).

The runner owns the listening socket (via L<Test2::Harness2::Role::Service>),
so this monitor is fed already-read frames or already-decoded payloads rather
than owning a socket of its own. It can then be queried for the collectors it
has seen, each one's status, events file, and (once complete) final result, plus
"what changed since I last asked" deltas -- L</new_collectors>, L</new_failing>,
L</new_test_exits>, and friends -- each of which drains and returns the uuids
that entered that state since the previous call.

A single C<runner.socket> serves every run a persistent runner executes; the
monitor folds them all into one canonical state. To let the runner route each
subscriber only its own run's data (per-run routing), the monitor
tracks the B<run association> that rides on every message -- the collector
C<run_uuid> on a collector transition and the C<run_id> on a runner-originated
job mutation. Those two identifiers are the same value: the runner stamps a test
collector's C<run_uuid> from the run's C<run_id> (see
L<Test2::Harness2::Runner::Job>), so a single key routes both kinds. Messages
with B<no> run association (the runner's own collector, preload-stage lifecycle
transitions) belong to a shared B<global bucket> that every subscriber sees.
L</run_for_payload> resolves a payload's run, and L</snapshot> can be filtered to
one run (plus the global bucket).

Besides collector transitions, the monitor also folds the small set of state
mutations the B<runner itself originates> -- a job being dispatched to a stage,
a job being forked (running), a job finishing (done). Those ride as a
C<harness_runner_job> facet (C<< {job_id, state, ...} >>) on the same wire form,
so the monitor is the single canonical fold of everything a subscribed client
needs to mirror the runner's view (ARCH 4.2 "two distinct runner outputs"): the
collector transitions every other collector reports B<and> the scheduler-origin
mutations the runner makes locally.

The monitor can serialize its whole canonical state with L</snapshot> and load a
serialized snapshot with L</apply_snapshot>, so a freshly-connected subscriber
gets a whole view and then keeps it whole by feeding forwarded frames (the
snapshot-plus-transitions contract, ARCH 4.2-4.3).

=head1 SYNOPSIS

    use Test2::Harness2::Runner::Monitor;

    my $mon = Test2::Harness2::Runner::Monitor->new;

    # Fold an already-decoded transition payload (one harness_collector message).
    $mon->feed($decoded_transition_payload);

    $_ and free_slot($_) for $mon->new_test_exits;

    # Serialize the whole canonical state for a new subscriber, and rebuild it
    # on the subscriber side.
    my $snap   = $mon->snapshot;
    my $mirror = Test2::Harness2::Runner::Monitor->new;
    $mirror->apply_snapshot($snap);

=cut

sub init ($self) {
    $self->{+COLLECTORS} = {};
    $self->{+JOBS}       = {};
    $self->{+RUNS}       = {};
    $self->{+RUN_HEALTH} = [];

    # The drain-on-call PENDING_* change lists are consumed only by subscriber-side
    # mirrors; the hub monitor (constructed track_pending => 0 by the runner) never
    # drains them, so it stops populating them entirely (#135 finding 3). Defaults on so
    # a plain mirror still tracks them.
    $self->{+TRACK_PENDING} //= 1;

    $self->{+PENDING_NEW}        = [];
    $self->{+PENDING_FAILING}    = [];
    $self->{+PENDING_DIAGNOSING} = [];
    $self->{+PENDING_COMPLETED}  = [];
    $self->{+PENDING_EXITS}      = [];
    $self->{+PENDING_FINALIZED}  = [];
    $self->{+PENDING_ABORTED}    = [];

    return;
}

=head1 PUBLIC METHODS

=over 4

=item $mon->feed($payload)

Fold one already-decoded transition message C<$payload> (a
C<< {facet_data =E<gt> ...} >> hashref carrying a C<harness_collector> facet)
into state.

=item @uuids = $mon->collectors

=item @uuids = $mon->tests

=item @uuids = $mon->services

The uuids of all collectors seen, or just the tests / just the (non-test)
service collectors.

=item collector

=item $state = $mon->collector($uuid)

The state hashref for one collector (or C<undef>): C<uuid>, C<category>
(C<test> / C<service>), C<name>, C<events_file>, C<try>, C<run_uuid>, C<status>
(C<running> / C<complete> / C<finalized>), the C<failing> / C<diagnosing>
flags, and C<final_state> once seen.

=item $status = $mon->status($uuid)

=item $path = $mon->events_file($uuid)

Conveniences for individual fields of L</collector>.

=item new_collectors

=item @uuids = $mon->new_collectors

=item new_failing

=item @uuids = $mon->new_failing

=item @uuids = $mon->new_diagnosing

=item @uuids = $mon->new_completed

=item new_test_exits

=item @uuids = $mon->new_test_exits

=item @uuids = $mon->new_finalized

Drain-on-call change lists: each returns the collector uuids that entered the
named state since the previous call to that method, then forgets them.
C<new_collectors> reports collectors seen for the first time (their events file
is available by then); C<new_test_exits> reports tests whose process has exited
(the C<completed> transition), which the scheduler uses to free a slot.
C<new_completed> also covers plain (non-test) collectors, which signal the end
of their run with an C<exited> transition instead of C<completed>.

=item new_aborted_jobs

=item @job_ids = $mon->new_aborted_jobs

Drain-on-call change list of job ids the runner watchdog aborted since the
previous call (a C<harness_runner_job> mutation with C<state> C<aborted>): a job
that was dispatched/running but whose collector will never report completion, so
the runner synthesized its failure into canonical state.

=item job_ids

=item @job_ids = $mon->job_ids

The ids of all jobs the runner has originated mutations for.

=item $bool = $mon->run_done($run_id)

True once the runner has announced that run as finished (a C<harness_run_end>
mutation). A run-scoped subscriber keys its completion on this: the persistent
runner serves many runs and does not close its socket after each one, so the
socket-close completion signal the transient path uses does not apply.

=item job

=item $state = $mon->job($job_id)

The runner-originated state hashref for one job (or C<undef>): C<job_id>,
C<state> (C<dispatched> / C<running> / C<done>), and the C<stage>, C<file>, and
C<run_id> the runner carried on the mutation.

=item $list = $mon->run_health

The suite-level health failures the runner reported (a post-pass collector
failure: a collector that failed after reporting a pass, so the test stays green
but the suite is marked failed). Each entry is a C<< {run_id, reason} >> hashref.

=item $snapshot = $mon->system_load

The latest system-load snapshot folded from a C<harness_system> message, or
C<undef> if none has arrived. Replaced (not accumulated) so it is always current.

=item run_for_payload

=item $run = $mon->run_for_payload($payload)

Resolve the run association of one decoded transition payload: the
C<harness_collector.run_uuid> on a collector transition, or the C<run_id> on a
runner-originated C<harness_runner_job> mutation. Returns C<undef> for a payload
with no run association (a global / stage-lifecycle message). Used by the runner
to route a forwarded frame to the right subscribers. A C<starting> collector
transition carries the C<run_uuid> directly; a later transition (only the uuid
rides) is resolved against the collector's already-tracked C<run_uuid>.

=item snapshot

=item $snapshot = $mon->snapshot

=item $snapshot = $mon->snapshot($run_id)

A serializable (plain data) snapshot of the canonical state: every tracked
collector and every tracked job. A subscriber gets this once on connect, then
keeps it whole by feeding forwarded frames. With a C<$run_id> the snapshot is
B<filtered> to that run plus the global bucket (collectors whose C<run_uuid>
matches or is undef, jobs whose C<run_id> matches or is undef), so a run-scoped
subscriber starts from only its own view. With no C<$run_id> the whole state is
returned (the global / C<watch> subscriber).

=item apply_snapshot

=item $mon->apply_snapshot($snapshot)

Load a serialized L</snapshot> into this (mirror) monitor, replacing its state.
Used by a subscriber so its local mirror starts from the runner's whole view.

=back

=cut

sub feed ($self, $payload) {
    $self->_process($payload);
    return;
}

sub collectors ($self) { return keys %{$self->{+COLLECTORS}} }

sub tests ($self) {
    return grep { ($self->{+COLLECTORS}{$_}{category} // '') eq 'test' }
        keys %{$self->{+COLLECTORS}};
}

sub services ($self) {
    return grep { ($self->{+COLLECTORS}{$_}{category} // '') eq 'service' }
        keys %{$self->{+COLLECTORS}};
}

sub collector ($self, $uuid) { return $self->{+COLLECTORS}{$uuid} }

sub status ($self, $uuid) {
    my $c = $self->{+COLLECTORS}{$uuid} or return undef;
    return $c->{status};
}

sub events_file ($self, $uuid) {
    my $c = $self->{+COLLECTORS}{$uuid} or return undef;
    return $c->{events_file};
}

sub new_collectors ($self) { return $self->_drain(PENDING_NEW) }
sub new_failing    ($self) { return $self->_drain(PENDING_FAILING) }
sub new_diagnosing ($self) { return $self->_drain(PENDING_DIAGNOSING) }
sub new_completed  ($self) { return $self->_drain(PENDING_COMPLETED) }
sub new_test_exits ($self) { return $self->_drain(PENDING_EXITS) }
sub new_finalized  ($self) { return $self->_drain(PENDING_FINALIZED) }

sub new_aborted_jobs ($self) { return $self->_drain(PENDING_ABORTED) }

sub job_ids ($self)          { return keys %{$self->{+JOBS}} }
sub job     ($self, $job_id) { return $self->{+JOBS}{$job_id} }

sub run_done ($self, $run_id) {
    return 0 unless defined $run_id;
    return $self->{+RUNS}{$run_id} ? 1 : 0;
}

sub run_for_payload ($self, $payload) {
    my $fd = ref($payload) eq 'HASH' ? $payload->{facet_data} : undef;
    return undef unless ref($fd) eq 'HASH';

    if (my $rj = $fd->{harness_runner_job}) {
        return $rj->{run_id};
    }

    if (my $re = $fd->{harness_run_end}) {
        return $re->{run_id};
    }

    if (my $rh = $fd->{harness_run_health}) {
        return $rh->{run_id};
    }

    my $hc = $fd->{harness_collector} or return undef;

    # A 'starting' transition carries run_uuid on the wire; later transitions
    # carry only the uuid, so fall back to the run_uuid we tracked at start.
    return $hc->{run_uuid} if defined $hc->{run_uuid};

    my $uuid = $hc->{uuid} // return undef;
    my $c    = $self->{+COLLECTORS}{$uuid} or return undef;
    return $c->{run_uuid};
}

sub snapshot ($self, $run_id = undef) {
    return {
        collectors  => $self->{+COLLECTORS},
        jobs        => $self->{+JOBS},
        runs        => $self->{+RUNS},
        run_health  => $self->{+RUN_HEALTH},
        system_load => $self->{+SYSTEM_LOAD},
    } unless defined $run_id;

    my %collectors;
    for my $uuid (keys %{$self->{+COLLECTORS}}) {
        my $c   = $self->{+COLLECTORS}{$uuid};
        my $run = $c->{run_uuid};
        $collectors{$uuid} = $c if !defined($run) || $run eq $run_id;
    }

    my %jobs;
    for my $job_id (keys %{$self->{+JOBS}}) {
        my $j   = $self->{+JOBS}{$job_id};
        my $run = $j->{run_id};
        $jobs{$job_id} = $j if !defined($run) || $run eq $run_id;
    }

    my %runs;
    $runs{$run_id} = $self->{+RUNS}{$run_id} if $self->{+RUNS}{$run_id};

    my @health = grep { !defined($_->{run_id}) || $_->{run_id} eq $run_id } @{$self->{+RUN_HEALTH} // []};

    # System load is global (run-less), so every run-scoped snapshot carries it too.
    return {collectors => \%collectors, jobs => \%jobs, runs => \%runs, run_health => \@health, system_load => $self->{+SYSTEM_LOAD}};
}

sub apply_snapshot ($self, $snapshot) {
    $self->{+COLLECTORS}  = $snapshot->{collectors}  // {};
    $self->{+JOBS}        = $snapshot->{jobs}        // {};
    $self->{+RUNS}        = $snapshot->{runs}        // {};
    $self->{+RUN_HEALTH}  = $snapshot->{run_health}  // [];
    $self->{+SYSTEM_LOAD} = $snapshot->{system_load};
    return;
}

# Prune all O(tests) hub-monitor state for a retired run (#135 finding 3): its tracked
# collectors (run_uuid eq run_id), jobs (run_id eq run_id), and run_health rows. The
# runner calls this from announce_run once the run's end frame has been forwarded, so
# no live subscriber still needs the folded per-collector/per-job detail; a
# late/reconnecting subscriber keys completion on the retained RUNS marker instead.
# Also runs a straggler sweep on EVERY call so a post-prune frame that recreated a
# stub does not leak: a collector stub with no run_uuid AND no category never saw its
# 'starting' transition (per-connection frame order guarantees a genuine collector
# 'starting's first), and a terminal job with no run linkage is a backfill-failed stray.
sub prune_run ($self, $run_id) {
    return unless defined $run_id;

    my $collectors = $self->{+COLLECTORS};
    for my $uuid (keys %$collectors) {
        my $run = $collectors->{$uuid}{run_uuid};
        delete $collectors->{$uuid} if defined($run) && $run eq $run_id;
    }

    my $jobs = $self->{+JOBS};
    for my $job_id (keys %$jobs) {
        my $run = $jobs->{$job_id}{run_id};
        delete $jobs->{$job_id} if defined($run) && $run eq $run_id;
    }

    @{$self->{+RUN_HEALTH}} = grep { !defined($_->{run_id}) || $_->{run_id} ne $run_id }
        @{$self->{+RUN_HEALTH} // []};

    for my $uuid (keys %$collectors) {
        my $c = $collectors->{$uuid};
        delete $collectors->{$uuid} if !defined($c->{run_uuid}) && !defined($c->{category});
    }

    for my $job_id (keys %$jobs) {
        my $j = $jobs->{$job_id};
        next if defined $j->{run_id};
        my $state = $j->{state} // '';
        delete $jobs->{$job_id} if $state eq 'done' || $state eq 'aborted' || $state eq 'requeued';
    }

    return;
}

# Drop a run's O(1) end marker (the retained RUNS entry) once it ages out of the
# runner's late-subscribe ring (#135 finding 3). Re-prune first to collect any
# collector/job/health a straggler frame recreated since the run retired.
sub drop_run_marker ($self, $run_id) {
    return unless defined $run_id;
    $self->prune_run($run_id);
    delete $self->{+RUNS}{$run_id};
    return;
}

# Suite-level health failures the runner reported (a post-pass collector failure,
# ARCHITECTURE.md §5.4). Returns the list of {run_id, reason} records.
sub run_health ($self) { return $self->{+RUN_HEALTH} // [] }

# The latest system-load snapshot (ARCHITECTURE.md §4.4), or undef if none has
# arrived. Published by the runner from a harness_system message; replaced (not
# accumulated) so it is always current.
sub system_load ($self) { return $self->{+SYSTEM_LOAD} }

=head1 PRIVATE METHODS

=over 4

=item @uuids = $self->_drain($slot)

Return and clear one of the pending change lists.

=item $self->_process($payload)

Fold one decoded message into per-collector state and the pending change lists,
keyed by the message's collector uuid.

=item $self->_process_transition($state_hash, $state, $hc)

Apply one C<harness_state_transition> (C<starting> / C<failing> /
C<diagnosing> / C<completed> / C<exited>) to a collector's state hash.

=item $self->_process_runner_job($rj)

Fold one runner-originated job mutation (a C<harness_runner_job> facet) into the
jobs map, keyed by C<job_id>.

=back

=cut

sub _drain ($self, $slot) {
    my $list = $self->{$slot};
    $self->{$slot} = [];
    return @$list;
}

sub _process ($self, $payload) {
    my $fd = $payload->{facet_data} or return;

    # A runner-originated job mutation (scheduler dispatch / fork / completion).
    # It carries no collector identity; fold it into the parallel jobs map.
    if (my $rj = $fd->{harness_runner_job}) {
        $self->_process_runner_job($rj);
        return;
    }

    # A runner-originated run-completion mutation: the runner has finished a run
    # (serialized, one at a time). A run-scoped subscriber keys its
    # completion on this, since the persistent runner does NOT close its socket
    # after a single run the way the transient runner does.
    if (my $re = $fd->{harness_run_end}) {
        $self->{+RUNS}{$re->{run_id}} = $re if defined $re->{run_id};
        return;
    }

    # A runner-originated suite-level health failure (ARCHITECTURE.md §5.4
    # "Post-pass collector failure"): a collector that failed AFTER reporting a
    # pass keeps its test green, but the runner saw its non-zero health exit on
    # reap and flags the SUITE failed so `yath test`/`run` exits non-zero. Record
    # the flag + its diagnostics; the renderer rolls it into the run's pass/fail.
    if (my $rh = $fd->{harness_run_health}) {
        push @{$self->{+RUN_HEALTH}} => $rh;
        return;
    }

    # A system-load snapshot (ARCHITECTURE.md §4.4): a global singleton, not a
    # lifecycle entity. Keep only the latest, so a snapshot taken for a late
    # subscriber carries current load.
    if (my $sys = $fd->{harness_system}) {
        $self->{+SYSTEM_LOAD} = $sys;
        return;
    }

    my $hc   = $fd->{harness_collector} or return;
    my $uuid = $hc->{uuid} // return;

    my $c = $self->{+COLLECTORS}{$uuid};
    unless ($c) {
        $c = $self->{+COLLECTORS}{$uuid} = {
            uuid       => $uuid,
            status     => 'running',
            failing    => 0,
            diagnosing => 0,
        };
        push @{$self->{+PENDING_NEW}} => $uuid if $self->{+TRACK_PENDING};
    }

    if (my $transition = $fd->{harness_state_transition}) {
        $self->_process_transition($c, $transition->{state}, $hc);
        return;
    }

    if (my $final = $fd->{harness_final_state}) {
        $c->{final_state} = $final;
        return;
    }

    if ($fd->{harness_collector_finalized}) {
        $c->{status} = 'finalized';
        push @{$self->{+PENDING_FINALIZED}} => $uuid if $self->{+TRACK_PENDING};
        return;
    }

    return;
}

sub _process_runner_job ($self, $rj) {
    my $job_id = $rj->{job_id} // return;

    my $j = $self->{+JOBS}{$job_id} //= {job_id => $job_id};

    $j->{state}   = $rj->{state}   if defined $rj->{state};
    $j->{stage}   = $rj->{stage}   if exists $rj->{stage};
    $j->{file}    = $rj->{file}    if exists $rj->{file};
    $j->{run_id}  = $rj->{run_id}  if exists $rj->{run_id};
    $j->{details} = $rj->{details} if exists $rj->{details};

    # A job the runner watchdog aborted (its collector will never report
    # completion) enters the 'aborted' state. Surface it on a drain-on-call
    # change list so a subscriber (the command-side driver) can render it as a
    # failed completion exactly once.
    push @{$self->{+PENDING_ABORTED}} => $job_id
        if $self->{+TRACK_PENDING} && defined($rj->{state}) && $rj->{state} eq 'aborted';

    return;
}

sub _process_transition ($self, $c, $state, $hc) {
    if ($state eq 'starting') {
        $c->{name}        = $hc->{name};
        $c->{events_file} = $hc->{events_file};
        $c->{try}         = $hc->{try};
        $c->{run_uuid}    = $hc->{run_uuid};
        $c->{category}    = defined $hc->{try} ? 'test' : 'service';
        $c->{status}      = 'running';
        return;
    }

    if ($state eq 'failing') {
        return if $c->{failing};
        $c->{failing} = 1;
        push @{$self->{+PENDING_FAILING}} => $c->{uuid} if $self->{+TRACK_PENDING};
        return;
    }

    if ($state eq 'diagnosing') {
        return if $c->{diagnosing};
        $c->{diagnosing} = 1;
        push @{$self->{+PENDING_DIAGNOSING}} => $c->{uuid} if $self->{+TRACK_PENDING};
        return;
    }

    if ($state eq 'completed') {
        $c->{status} = 'complete';
        if ($self->{+TRACK_PENDING}) {
            push @{$self->{+PENDING_COMPLETED}} => $c->{uuid};
            push @{$self->{+PENDING_EXITS}} => $c->{uuid}
                if ($c->{category} // '') eq 'test';
        }
        return;
    }

    # Plain (non-test) collectors have no auditor; the collector itself emits an
    # 'exited' transition in place of the auditor's 'completed'.
    if ($state eq 'exited') {
        $c->{status} = 'complete';
        push @{$self->{+PENDING_COMPLETED}} => $c->{uuid} if $self->{+TRACK_PENDING};
        return;
    }

    return;
}

1;

__END__

=pod

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
