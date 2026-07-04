use Test2::V0;
# HARNESS-DURATION-SHORT

use Test2::Harness2::Runner::State;

# bloat TODO-3: requeue_task puts a RUNNING task back into the PENDING queue to be
# re-resolved on a later tick WITHOUT consuming a retry -- the safe path for a job
# that was started (slot/resources consumed) but never accepted by a stage (the
# assign->launch race). Distinct from retry_task (consumes a try) and abort_job
# (fails the job).
#
# Bypass the heavy init; drive the task lifecycle directly with no resources and a
# non-staged map so task_stage resolves to 'default'.
{
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
        job_id   => 'JOB-1',
        run_id   => 'R1',
        file     => 't/x.t',
        category => 'general',
        duration => 'medium',
        use_preload => 1,
        is_try   => 1,    # 1-based first try (R10 / TODO-49)
        %over,
    };
}

subtest requeue_releases_slot_and_keeps_try => sub {
    my $state = FakeState->new(preloader => undef, stage_map => undef);

    my $task = mk_task();
    $state->queue_task($task);

    # Start it: mark RUNNING with the resolved stage (as start_task does).
    $state->start_task({job_id => 'JOB-1', stage => 'default', res => {record => {}, env_vars => {}, args => []}});

    is($state->{running}, 1, "one task running after start");
    ok($state->running_tasks->{'JOB-1'}, "the task is tracked as running");

    $state->requeue_task('JOB-1');

    is($state->{running}, 0, "running slot released after requeue");
    ok(!$state->running_tasks->{'JOB-1'}, "no longer tracked as running");

    # It is back in the queue (TASK_LOOKUP) with the same job_id and an UNCHANGED
    # try number -- a requeue does not consume a retry.
    my $requeued = $state->{task_lookup}{'JOB-1'};
    ok($requeued, "the task is back in the queue (TASK_LOOKUP)");
    is($requeued->{is_try}, 1, "try number unchanged -- no retry consumed");
};

subtest requeue_does_not_requeue_a_halted_run => sub {
    my $state = FakeState->new(preloader => undef, stage_map => undef);

    my $task = mk_task(job_id => 'JOB-2');
    $state->queue_task($task);
    $state->start_task({job_id => 'JOB-2', stage => 'default', res => {record => {}, env_vars => {}, args => []}});

    $state->{halted_runs}{'R1'} = 1;
    $state->requeue_task('JOB-2');

    is($state->{running}, 0, "slot still released even for a halted run");
    ok(!$state->{task_lookup}{'JOB-2'}, "a halted run's task is NOT re-queued");
};

done_testing;
