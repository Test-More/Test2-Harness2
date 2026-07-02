use Test2::V0;
# HARNESS-DURATION-SHORT

# #135 finding 29: _start_task mutated the env_vars/test_args refs SHARED with the
# canonical TASK_LOOKUP task (and the finder's TestFile), so per-attempt resource args
# accumulated across retries -- a retry re-copied a contaminated task and stamped the
# resource args on top of the prior attempt's. _start_task must make a fully-owned copy
# (its own env_vars hash + test_args array) so the running copy carries EXACTLY ONE
# instance of each per-attempt resource arg and the canonical task stays pristine.

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
        job_id    => 'JOB-1',
        run_id    => 'R1',
        file      => 't/x.t',
        category  => 'general',
        duration  => 'medium',
        use_preload => 1,
        is_try    => 1,
        env_vars  => {BASE => 'b'},
        test_args => ['--base'],
        conflicts => [],
        %over,
    };
}

# A resource assignment: one env var + one per-attempt arg (the Resource API shape).
sub res_alloc { return {record => {}, env_vars => {RES => 'r'}, args => ['--res=1']} }

subtest canonical_task_stays_pristine => sub {
    my $state = FakeState->new(preloader => undef, stage_map => undef);

    my $orig = mk_task();
    my $orig_env  = $orig->{env_vars};
    my $orig_args = $orig->{test_args};
    $state->_queue_task($orig);

    $state->_start_task({job_id => 'JOB-1', stage => 'default', res => res_alloc()});

    my $running = $state->running_tasks->{'JOB-1'};
    my $lookup  = $state->{task_lookup}{'JOB-1'};

    # The running copy carries the resource env/arg.
    is($running->{env_vars}{RES}, 'r', "running copy carries the resource env var");
    is($running->{test_args}, ['--base', '--res=1'], "running copy carries exactly one resource arg");

    # The canonical TASK_LOOKUP task is UNMUTATED (no resource leakage) ...
    ok(!exists $lookup->{env_vars}{RES}, "TASK_LOOKUP env_vars did not gain the resource var");
    is($lookup->{test_args}, ['--base'], "TASK_LOOKUP test_args did not gain the resource arg");

    # ... and its containers are DISTINCT refs from the running copy's (a true copy,
    # not an alias), so a later mutation of one cannot bleed into the other.
    ref_is_not($running->{env_vars},  $lookup->{env_vars},  "env_vars is a distinct ref");
    ref_is_not($running->{test_args}, $lookup->{test_args}, "test_args is a distinct ref");
    ref_is($lookup->{env_vars},  $orig_env,  "TASK_LOOKUP still holds the original env_vars ref");
    ref_is($lookup->{test_args}, $orig_args, "TASK_LOOKUP still holds the original test_args ref");
};

subtest retry_carries_exactly_one_copy_of_per_attempt_args => sub {
    my $state = FakeState->new(preloader => undef, stage_map => undef);

    $state->_queue_task(mk_task());

    # First attempt: start with the per-attempt resource arg.
    $state->_start_task({job_id => 'JOB-1', stage => 'default', res => res_alloc()});

    # Genuine failure -> retry (consumes a try, re-queues from the pristine lookup).
    $state->retry_task('JOB-1');
    is($state->{task_lookup}{'JOB-1'}{is_try}, 2, "retry incremented the try to 2");
    is($state->{task_lookup}{'JOB-1'}{test_args}, ['--base'], "the re-queued task has NO leftover resource arg");

    # Second attempt: start again with the SAME per-attempt resource arg.
    $state->_start_task({job_id => 'JOB-1', stage => 'default', res => res_alloc()});

    my $running = $state->running_tasks->{'JOB-1'};
    my $count = grep { $_ eq '--res=1' } @{$running->{test_args}};
    is($count, 1, "the retried running copy carries EXACTLY ONE copy of the per-attempt arg");
    is($running->{test_args}, ['--base', '--res=1'], "no duplication across the retry");
};

done_testing;
