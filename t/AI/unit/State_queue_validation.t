use Test2::V0;
# HARNESS-DURATION-SHORT

use Test2::Harness2::Runner::State;

# TODO-118 ingress backstop. queue_task is the one funnel every task passes through
# (queue_task / retry_task / requeue_task all reach it), including the un-eval'd
# flush_submit_buffer replay path TODO-110's dispatch eval cannot see. task_fields
# dies on an out-of-domain category/duration, which -- pre-TODO-118 -- aborted the
# whole run (and, on a persistent daemon, reaped sibling runs). The backstop
# normalizes an invalid category/duration IN PLACE (warn + default) so a bad
# task becomes a survivable task, never a run abort.
#
# Bypass the heavy init; drive the task lifecycle directly with no resources and
# a non-staged map so task_stage resolves to 'default'.
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
        job_id      => 'JOB-1',
        run_id      => 'R1',
        file        => 't/x.t',
        rel_file    => 't/x.t',
        category    => 'general',
        duration    => 'medium',
        use_preload => 1,
        is_try      => 1,
        %over,
    };
}

subtest invalid_category_and_duration_normalized => sub {
    my $state = FakeState->new(preloader => undef, stage_map => undef);

    my $task = mk_task(category => 'network', duration => '42');

    my $warnings = warnings { $state->queue_task($task) };
    is(@$warnings, 2, "exactly two warnings (one per invalid field)");
    like($warnings->[0], qr/\Qt\/x.t\E/, "warning names the rel_file");
    like($warnings->[0], qr/invalid category 'network'/, "category warning names the bad token");
    like($warnings->[1], qr/invalid duration '42'/,      "duration warning names the bad token");

    # Normalized IN PLACE: the stored task (same hashref) now holds valid values.
    is($task->{category}, 'general', "category defaulted in place");
    is($task->{duration}, 'medium',  "duration defaulted in place");
    ok($state->{task_lookup}{'JOB-1'}, "task was queued, not rejected");

    # task_fields -- the die site -- no longer dies for this data.
    my @fields;
    ok(lives { @fields = $state->task_fields($task) }, "task_fields does not die")
        or diag($@);
    is($fields[3], 'general', "task_fields resolves the normalized category");
    is($fields[4], 'medium',  "task_fields resolves the normalized duration");
};

subtest undef_and_ref_values_normalized => sub {
    my $state = FakeState->new(preloader => undef, stage_map => undef);

    my $task = mk_task(job_id => 'JOB-2', category => undef, duration => [1, 2, 3]);

    my $warnings = warnings { $state->queue_task($task) };
    is(@$warnings, 2, "undef and ref values each warn once");
    is($task->{category}, 'general', "undef category defaulted");
    is($task->{duration}, 'medium',  "ref duration defaulted");

    ok(lives { $state->task_fields($task) }, "task_fields survives normalized undef/ref values")
        or diag($@);
};

subtest well_formed_task_is_silent => sub {
    my $state = FakeState->new(preloader => undef, stage_map => undef);

    my $task = mk_task(job_id => 'JOB-3', category => 'isolation', duration => 'long');
    is(warnings { $state->queue_task($task) }, [], "a valid task warns nothing");
    is($task->{category}, 'isolation', "valid category untouched");
    is($task->{duration}, 'long',      "valid duration untouched");
};

subtest one_bad_task_does_not_reap_sibling_runs => sub {
    # A bad directive must NEVER abort the run or take down other queued runs on
    # a persistent runner. Queue a bad task in R1 and a good task in R2; the bad
    # one warns+normalizes without dying, and R2's task is wholly unaffected.
    my $state = FakeState->new(preloader => undef, stage_map => undef);

    my $good = mk_task(job_id => 'GOOD', run_id => 'R2');
    $state->queue_task($good);

    my $bad = mk_task(job_id => 'BAD', run_id => 'R1', category => 'network', duration => 'nope');
    my $lived = 0;
    my $warnings = warnings { $lived = lives { $state->queue_task($bad) } };
    ok($lived, "a bad task never dies out of queue_task") or diag($@);
    is(@$warnings, 2, "the bad task warned about both fields");

    ok($state->{task_lookup}{'GOOD'}, "the sibling run's task is still queued");
    ok($state->{task_lookup}{'BAD'},  "the bad task was normalized and queued too");
    is($good->{category}, 'general', "the sibling task was not mutated");
    is($good->{duration}, 'medium',  "the sibling task was not mutated");
};

done_testing;
