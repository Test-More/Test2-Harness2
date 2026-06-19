use Test2::V0;
# HARNESS-DURATION-SHORT

use Test2::Harness2::Runner::State;

# Bypass the heavy init (settings/workdir/resources): we exercise only the stage
# lifecycle tracking.
{
    package FakeState;
    our @ISA = ('Test2::Harness2::Runner::State');
    sub init {}
}

# Chunk 19.5 (§6.8): named stage lifecycle states. STAGE_READINESS stays the
# dispatch gate (truthy == schedulable); STAGE_LIFECYCLE is the richer parallel
# record {state, generation, ...}. 'up' is schedulable; 'restarting'/'down' are not.
subtest up_down_restarting => sub {
    my $state = FakeState->new();

    $state->stage_ready('moose', 7);
    ok($state->stage_readiness->{moose}, "ready stage is schedulable (gate truthy)");
    is($state->stage_lifecycle->{moose}{state},      'up', "lifecycle state is 'up'");
    is($state->stage_lifecycle->{moose}{generation}, 7,    "generation recorded");

    $state->stage_restarting('moose', 7);
    is($state->stage_readiness->{moose}, 0, "a restarting stage is NOT schedulable");
    is($state->stage_lifecycle->{moose}{state}, 'restarting', "lifecycle state is 'restarting'");

    $state->stage_ready('moose', 8);
    ok($state->stage_readiness->{moose}, "re-readied stage is schedulable again");
    is($state->stage_lifecycle->{moose}{state},      'up', "back to 'up'");
    is($state->stage_lifecycle->{moose}{generation}, 8,    "new generation recorded");

    $state->stage_down('moose', 8);
    is($state->stage_readiness->{moose}, 0, "a down stage is NOT schedulable");
    is($state->stage_lifecycle->{moose}{state}, 'down', "lifecycle state is 'down'");
};

subtest reset_clears_both => sub {
    my $state = FakeState->new();
    $state->stage_ready('a', 1);
    $state->stage_ready('b', 1);

    $state->reset_stage_readiness;

    is($state->stage_readiness, {}, "readiness cleared on reset (respawn)");
    is($state->stage_lifecycle, {}, "lifecycle cleared on reset (respawn)");
};

subtest generation_optional => sub {
    # The in-runner (no preload-root) path reports without a generation.
    my $state = FakeState->new();
    $state->stage_ready('base');
    is($state->stage_lifecycle->{base}{state}, 'up', "state tracked without a generation");
    ok(!exists $state->stage_lifecycle->{base}{generation}, "no generation key when none given");
};

done_testing;
