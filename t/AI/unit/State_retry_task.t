use Test2::V0;
# HARNESS-DURATION-SHORT

# #117: State::retry_task must report whether it ACTUALLY re-queued the
# job, so the completion decision (Completion::_collector_retry_if_tries) can tell a
# real retry from a declined one. A halted run stops the current try (releases the
# slot and resources) but MUST NOT re-queue it and MUST report the decline (return
# false) -- otherwise the runner announces a 'retry' that never materializes and the
# job is reported under "the following jobs never ran".
#
# Bypass the heavy init; drive the task lifecycle directly with no resources and a
# non-staged map so task_stage resolves to 'default'.

use Test2::Harness2::Runner::State;

{
    package FakeRun;
    sub new { bless {run_id => 'R1', retry_isolated => 0}, $_[0] }
    sub run_id         { $_[0]->{run_id} }
    sub retry_isolated { $_[0]->{retry_isolated} }

    package FakeState;
    our @ISA = ('Test2::Harness2::Runner::State');
    sub init {
        my $self = shift;
        $self->{resources} = [];
        $self->{running}   = 0;
        $self->{run}       = FakeRun->new;
    }
}

sub mk_task {
    my %over = @_;
    return {
        job_id      => 'JOB-1',
        run_id      => 'R1',
        file        => 't/x.t',
        category    => 'general',
        duration    => 'medium',
        use_preload => 1,
        is_try      => 1,    # 1-based first try (R10 / #49)
        %over,
    };
}

subtest retry_requeues_and_reports_true => sub {
    my $state = FakeState->new(preloader => undef, stage_map => undef);

    $state->queue_task(mk_task());
    $state->start_task({job_id => 'JOB-1', stage => 'default', res => {record => {}, env_vars => {}, args => []}});

    ok($state->running_tasks->{'JOB-1'}, "task is running before retry");

    my $queued = $state->retry_task('JOB-1');

    ok($queued, "retry_task returns truthy when it actually re-queued the job");
    is($state->{running}, 0, "running slot released");
    ok(!$state->running_tasks->{'JOB-1'}, "no longer tracked as running");

    my $requeued = $state->{task_lookup}{'JOB-1'};
    ok($requeued, "the task is back in the queue (TASK_LOOKUP)");
    is($requeued->{is_try}, 2, "the retry consumed a try (is_try 1 -> 2)");
};

subtest halted_run_declines_and_reports_false => sub {
    my $state = FakeState->new(preloader => undef, stage_map => undef);

    $state->queue_task(mk_task(job_id => 'JOB-2'));
    $state->start_task({job_id => 'JOB-2', stage => 'default', res => {record => {}, env_vars => {}, args => []}});

    $state->{halted_runs}{'R1'} = 1;

    my $queued = $state->retry_task('JOB-2');

    ok(!$queued, "retry_task returns false when the run is halted (declined)");
    is($state->{running}, 0, "the slot is still released on a declined retry -- no dangling RUNNING");
    ok(!$state->{task_lookup}{'JOB-2'}, "a halted run's task is NOT re-queued");
    ok(!$state->running_tasks->{'JOB-2'}, "not tracked as running after a declined retry");
};

done_testing;
