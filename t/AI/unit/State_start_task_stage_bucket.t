use Test2::V0;
# HARNESS-DURATION-SHORT

# TODO-115: task_stage is RE-RESOLVED at start time and can diverge from the queue-time
# bucket. A task whose preload_list is [alpha, beta] buckets under 'beta' while
# 'alpha' is still 'starting' ('first up wins' -> beta). If 'alpha' readies before
# the task is dispatched, _next still pulls the task from the 'beta' bucket (it was
# never rebucketed) and dispatches it with run_stage => 'beta'. The old start_task
# re-resolved task_stage to 'alpha' and looked in the (empty) 'alpha' bucket, so the
# PENDING_TASKS removal missed: the runner died with "Task <id> was not pending"
# (or an undef-array-deref on the absent bucket), killing every running job.
#
# The fix: start_task must remove from the bucket _next dequeued the task from --
# $spec->{stage} (run_stage) -- not from a fresh task_stage re-resolution.
#
# Bypass the heavy init; drive the stage lifecycle + task queue directly with no
# resources so _next resolves purely on stage buckets.

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
        job_id       => 'JOB-1',
        run_id       => 'R1',
        file         => 't/x.t',
        category     => 'general',
        duration     => 'medium',
        use_preload  => 1,
        preload_list => ['alpha', 'beta'],
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

# beta is up, alpha is still 'starting'; the [alpha, beta] task buckets under beta.
sub mk_state_beta_up_alpha_starting {
    my $map = {alpha => {}, beta => {}, default => {default => 1}};
    my $state = FakeState->new(preloader => undef, stage_map => $map);
    $state->set_stage_map($map);      # all three -> 'starting'
    $state->stage_ready('beta');      # only beta becomes 'up'
    return $state;
}

subtest preferred_stage_readies_late => sub {
    my $state = mk_state_beta_up_alpha_starting();

    $state->queue_task(mk_task());
    is([bucket_stages($state, 'R1')], ['beta'],
        "task with preload_list [alpha, beta] buckets under 'beta' while 'alpha' is still starting");

    # The preferred stage 'alpha' readies before the task is dispatched. The task is
    # NOT rebucketed, so it still sits in the 'beta' bucket -- but task_stage now
    # re-resolves the [alpha, beta] task to 'alpha' ('first up wins').
    $state->stage_ready('alpha');
    is($state->task_stage($state->{task_lookup}{'JOB-1'}), 'alpha',
        "task_stage now re-resolves to 'alpha' (the divergence from the queue-time bucket)");
    is([bucket_stages($state, 'R1')], ['beta'],
        "the task is still parked in the 'beta' bucket it was queued into");

    # advance_tasks -> _next dequeues from the 'beta' bucket and dispatches with
    # run_stage => 'beta'. This is the exact crash surface: the old start_task
    # re-resolved to 'alpha' and died "was not pending".
    my $out;
    my $ok = eval { $out = $state->advance_tasks; 1 };
    my $err = $@;
    ok($ok, "advance_tasks dispatches the task without dying on a stage-bucket miss")
        or diag($err);
    is($out, 1, "a task was started");

    # The task ran on 'beta' -- the bucket it was actually dispatched from -- and the
    # 'beta' bucket was pruned, not the (never-populated) 'alpha' bucket.
    my $running = $state->running_tasks->{'JOB-1'};
    ok($running, "the task is now running");
    is($running->{stage}, 'beta', "the running copy carries the dispatched (bucket) stage 'beta'");
    is([bucket_stages($state, 'R1')], [], "the 'beta' bucket was drained; no bucket stranded");

    # No task is left parked in ANY PENDING_TASKS bucket for the run -- the removal
    # landed in the right ('beta') bucket, not a phantom 'alpha' one.
    my $remaining = 0;
    if (my $by_smoke = $state->{pending_tasks}{'R1'}) {
        for my $by_stage (values %$by_smoke) {
            for my $by_cat (values %$by_stage) {
                for my $by_dur (values %$by_cat) {
                    $remaining += @$_ for values %$by_dur;
                }
            }
        }
    }
    is($remaining, 0, "no task left parked in any PENDING_TASKS bucket");
};

subtest restarting_stage_returns_up_mid_run => sub {
    # Persistent-runner variant: a stage that goes 'restarting' after a task bucketed
    # elsewhere comes back 'up' before dispatch. Same divergence, same fix.
    my $state = mk_state_beta_up_alpha_starting();
    $state->stage_ready('alpha');       # both up
    $state->stage_restarting('alpha');  # alpha temporarily down again

    # [alpha, beta]: alpha is 'restarting' (not up), beta up -> buckets under beta.
    $state->queue_task(mk_task());
    is([bucket_stages($state, 'R1')], ['beta'], "task buckets under 'beta' while 'alpha' restarts");

    # alpha's fresh incarnation re-readies before dispatch.
    $state->stage_ready('alpha');

    my $out;
    my $ok = eval { $out = $state->advance_tasks; 1 };
    my $err = $@;
    ok($ok, "advance_tasks survives the restarting->up divergence") or diag($err);
    is($state->running_tasks->{'JOB-1'}{stage}, 'beta', "task runs on its dispatched stage 'beta'");
};

done_testing;
