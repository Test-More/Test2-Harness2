use Test2::V0;
# HARNESS-DURATION-SHORT

# TODO-135 finding 27: demoting a stage to 'down' strands its PENDING_TASKS bucket --
# _next only walks 'up' stage buckets, so a task left parked in the demoted stage is
# unreachable and the run hangs forever. stage_down (and set_stage_map's removed-stage
# loop, which now routes through it) must REBUCKET the demoted stage's parked tasks so
# task_stage re-resolves them into a schedulable bucket.
#
# Bypass the heavy init; drive the stage lifecycle + task queue directly with no
# resources so _next resolves purely on stage buckets.

use Test2::Harness2::Runner::State;

{
    package FakeRun;
    sub new { bless {run_id => $_[1]}, $_[0] }
    sub run_id { $_[0]->{run_id} }

    package FakeState;
    our @ISA = ('Test2::Harness2::Runner::State');
    sub init {
        my $self = shift;
        $self->{resources} = [];
        $self->{running}   = 0;
    }
}

sub mk_task {
    my %over = @_;
    return {
        job_id       => 'JOB-1',
        run_id       => 'R1',
        file         => 't/x.t',
        category     => 'general',
        duration     => 'medium',
        use_preload  => 1,
        preload_list => ['S'],
        conflicts    => [],
        is_try       => 1,
        %over,
    };
}

# The stage keys a run's tasks are bucketed under (PENDING_TASKS run->smoke->STAGE).
sub bucket_stages {
    my ($state, $run_id) = @_;
    my $main = $state->{pending_tasks}{$run_id}{main} or return ();
    return sort keys %$main;
}

sub mk_state_with_S_up {
    my $state = FakeState->new(preloader => undef, stage_map => {S => {}, default => {default => 1}});
    $state->set_stage_map({S => {}, default => {default => 1}});
    $state->stage_ready('S');
    $state->stage_ready('default');
    $state->{run} = FakeRun->new('R1');
    return $state;
}

subtest stage_down_endpoint_drains_bucket => sub {
    my $state = mk_state_with_S_up();

    $state->queue_task(mk_task());
    is([bucket_stages($state, 'R1')], ['S'], "task is parked in the 'S' bucket while S is up");

    # The stage_down request endpoint (Handlers stage_down) demotes S.
    $state->stage_down('S');

    is([bucket_stages($state, 'R1')], ['default'], "the 'S' bucket is drained and the task re-resolves to 'default'");

    # It is now reachable by the scheduler: _next only walks 'up' buckets, and it
    # returns the re-resolved task bound to the 'default' run-stage.
    my ($run_stage, $task) = $state->_next;
    is($run_stage, 'default', "_next dispatches the rebucketed task via the 'default' stage");
    is($task->{job_id}, 'JOB-1', "the same task is startable after the demotion");
};

subtest set_stage_map_removed_stage_drains_bucket => sub {
    my $state = mk_state_with_S_up();

    $state->queue_task(mk_task());
    is([bucket_stages($state, 'R1')], ['S'], "task is parked in the 'S' bucket");

    # A reload drops S from the map entirely (the removed-stage demotion path).
    $state->set_stage_map({default => {default => 1}});

    is([bucket_stages($state, 'R1')], ['default'], "removing S from the map drains its bucket and re-resolves the task");
    is($state->stage_state('S'), 'down', "S is marked permanently down");

    my ($run_stage, $task) = $state->_next;
    is($run_stage, 'default', "_next dispatches the rebucketed task after the map refresh");
    is($task->{job_id}, 'JOB-1', "the queued task completes rather than stranding");
};

subtest empty_bucket_demotion_is_a_noop => sub {
    my $state = mk_state_with_S_up();
    # No tasks parked; demotion must not die on an empty/absent bucket.
    ok(lives { $state->stage_down('S') }, "stage_down with no parked tasks is a no-op");
    is([bucket_stages($state, 'R1')], [], "no buckets materialized");
};

done_testing;
