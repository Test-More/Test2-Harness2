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

# §6.8 (chunk 19.5, bloat #2): named stage lifecycle states are the SINGLE source of
# stage scheduling state -- the old parallel STAGE_READINESS map is gone. The
# converged dispatch gate is `state eq 'up'` (stage_is_up). The four states are
# starting / up / restarting / down; only 'up' is dispatchable.
subtest up_restarting_down => sub {
    my $state = FakeState->new();

    $state->stage_ready('moose');
    ok($state->stage_is_up('moose'), "ready stage is schedulable (gate == 'up')");
    is($state->stage_lifecycle->{moose}{state}, 'up', "lifecycle state is 'up'");
    ok(defined $state->stage_lifecycle->{moose}{stamp}, "stamp recorded");

    $state->stage_restarting('moose');
    ok(!$state->stage_is_up('moose'), "a restarting stage is NOT schedulable");
    is($state->stage_lifecycle->{moose}{state}, 'restarting', "lifecycle state is 'restarting'");

    $state->stage_ready('moose');
    ok($state->stage_is_up('moose'), "re-readied stage is schedulable again");
    is($state->stage_lifecycle->{moose}{state}, 'up', "back to 'up'");

    $state->stage_down('moose');
    ok(!$state->stage_is_up('moose'), "a down stage is NOT schedulable");
    is($state->stage_lifecycle->{moose}{state}, 'down', "lifecycle state is 'down'");
};

# §6.8: the reported stage map commits stages as 'starting' (known, not yet ready);
# a stage absent from a refreshed map is permanently 'down'.
subtest stage_map_drives_starting_and_down => sub {
    my $state = FakeState->new();

    $state->set_stage_map({alpha => {}, beta => {}});
    is($state->stage_lifecycle->{alpha}{state}, 'starting', "committed stage is 'starting'");
    is($state->stage_lifecycle->{beta}{state},  'starting', "committed stage is 'starting'");
    ok(!$state->stage_is_up('alpha'), "a starting stage is NOT schedulable");

    # alpha readies; a refresh that keeps alpha and drops beta leaves alpha 'up' and
    # marks beta (now absent) permanently 'down'.
    $state->stage_ready('alpha');
    $state->set_stage_map({alpha => {}});
    is($state->stage_lifecycle->{alpha}{state}, 'up',   "an already-up stage stays 'up' across a refresh");
    is($state->stage_lifecycle->{beta}{state},  'down', "a stage absent from the refreshed map is 'down'");
};

subtest reset_clears_lifecycle => sub {
    my $state = FakeState->new();
    $state->stage_ready('a');
    $state->stage_ready('b');

    $state->reset_stage_readiness;

    is($state->stage_lifecycle, {}, "lifecycle cleared on reset (respawn)");
};

# bloat #3: the lifecycle record is {state, stamp} only -- stale-incarnation
# rejection moved to connection-currency in the runner's stage-report handlers, so
# there is no wire-generation field anywhere in the lifecycle.
subtest lifecycle_has_no_generation => sub {
    my $state = FakeState->new();
    $state->stage_ready('base');
    is($state->stage_lifecycle->{base}{state}, 'up', "state tracked");
    ok(defined $state->stage_lifecycle->{base}{stamp}, "stamp present");
    ok(!exists $state->stage_lifecycle->{base}{generation}, "no generation key in the lifecycle record");
    is([sort keys %{$state->stage_lifecycle->{base}}], ['stamp', 'state'], "lifecycle record is exactly {state, stamp}");
};

done_testing;
