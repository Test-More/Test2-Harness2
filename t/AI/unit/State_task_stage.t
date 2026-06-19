use Test2::V0;
# HARNESS-DURATION-SHORT

use Test2::Harness2::Runner::State;

# Bypass the heavy init (settings/workdir/resources) -- task_stage only reads
# preloader / stage_map / file_stage_resolver.
{
    package FakeState;
    our @ISA = ('Test2::Harness2::Runner::State');
    sub init {}
}

# Chunk 19 regression: in the scheduler-only path (no in-runner preloader) a
# NON-staged preload reports an EMPTY stage map, and the preload-root hosts only
# the base stage, which registers as lowercase 'default'. An unstaged task must
# therefore resolve to 'default' -- NOT 'DEFAULT', which would dispatch to a
# 'preload-DEFAULT' that never registered and abort the job as "stage gone".
subtest empty_map_resolves_to_lowercase_default => sub {
    my $state = FakeState->new(preloader => undef, stage_map => undef);

    is($state->task_stage({use_preload => 1}), 'default',
        "empty stage map + no directive => 'default' (lowercase)");

    is($state->task_stage({use_preload => 1, stage => undef}), 'default',
        "undef directive => 'default'");
};

subtest no_preload_is_NOPRELOAD => sub {
    my $state = FakeState->new(preloader => undef, stage_map => undef);

    is($state->task_stage({use_preload => 0}), 'NOPRELOAD',
        "use_preload => 0 => the synthetic NOPRELOAD stage");
};

subtest directive_and_map_resolution => sub {
    my $state = FakeState->new(
        preloader => undef,
        stage_map => {default => {can_run => [], default => 1}, MOOSE => {can_run => []}},
    );

    is($state->task_stage({use_preload => 1, stage => 'MOOSE'}), 'MOOSE',
        "a valid directive stage in the map wins");

    is($state->task_stage({use_preload => 1, stage => undef}), 'default',
        "no directive => the map's default stage");
};

done_testing;
