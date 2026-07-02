use Test2::V0;
# HARNESS-DURATION-SHORT

# #135 finding 28: a run activated AND retired within a single advance loop was never
# announced -- the old before/after ACTIVE_RUN slot diff only saw a run that occupied
# the +RUN slot ACROSS the tick. Its harness_run_end was lost (hanging a run-scoped
# subscriber) and, on the owner-drop leg, it leaked in state. The fix records each
# retirement as an EVENT (State::clear_finished_run -> retired_run_ids), which the
# scheduler drains (take_retired_runs) and announces after the advance loop, so EVERY
# retirement -- including same-tick activate+retire -- is announced exactly once.

use Test2::Harness2::Runner::State;

{
    package FakeRun;
    sub new { bless {run_id => $_[1]}, $_[0] }
    sub run_id { $_[0]->{run_id} }

    package FakeState;
    our @ISA = ('Test2::Harness2::Runner::State');
    sub init { $_[0]->{resources} = []; }
}

subtest state_records_retirement_as_a_drainable_event => sub {
    my $state = FakeState->new(preloader => undef, stage_map => undef);

    # A run that finished (stopped, no pending tasks, nothing running).
    $state->{run} = FakeRun->new('R1');
    $state->{stopped_runs}{R1} = 1;
    $state->{running} = 0;

    ok($state->clear_finished_run, "clear_finished_run retires the finished run");
    is([$state->take_retired_runs], ['R1'], "the retirement is drainable as an event");
    is([$state->take_retired_runs], [], "the drain is destructive -- the event is returned exactly once");
};

# A mock state whose advance() retires a scripted set of runs per step, accumulating
# them all in one scheduler_tick's while-loop (exactly the same-tick multi-retire the
# slot-diff missed).
{
    package MockSchedState;
    sub new { bless {retired => [], script => $_[1] // []}, $_[0] }
    sub run { undef }
    sub advance {
        my $self = shift;
        my $step = shift @{$self->{script}} or return 0;
        push @{$self->{retired}} => @$step;
        return 1;
    }
    sub take_retired_runs { my $self = shift; my @r = @{$self->{retired}}; $self->{retired} = []; return @r }
    sub resource_timeout { 0 }

    package FakeScheduler;
    use Role::Tiny::With;
    with 'Test2::Harness2::Runner::Role::Scheduler';
    sub new { bless {state => $_[1], announced => [], resource_timeout => 0}, $_[0] }
    sub state            { $_[0]->{state} }
    sub announce_run     { push @{$_[0]->{announced}} => $_[1]; return }
    sub dispatch_pending { return }
    sub service_stopped  { 0 }
    sub _enforce_collector_connect_timeout { return }
    sub _enforce_terminate_grace           { return }
    sub _flush_run_ledger_sweeps           { return }
}

subtest one_tick_announces_a_run_activated_and_retired_together => sub {
    # A queued run stopped with zero tasks retires on the first advance step, never
    # occupying the +RUN slot across ticks: one scheduler_tick -> exactly one announce.
    my $sched = FakeScheduler->new(MockSchedState->new([['R1']]));

    $sched->scheduler_tick;
    is($sched->{announced}, ['R1'], "one harness_run_end announced for the same-tick retirement");

    $sched->scheduler_tick;    # nothing left to retire
    is($sched->{announced}, ['R1'], "a second tick re-announces nothing (destructive drain)");
};

subtest one_tick_announces_multiple_retirements_in_order => sub {
    # A retires, then B activates+retires, all within one advance loop.
    my $sched = FakeScheduler->new(MockSchedState->new([['A'], ['B']]));

    $sched->scheduler_tick;
    is($sched->{announced}, ['A', 'B'], "both same-tick retirements announced, in retire order");

    $sched->scheduler_tick;
    is($sched->{announced}, ['A', 'B'], "the second tick announces nothing new");
};

done_testing;
