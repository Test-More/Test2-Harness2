use Test2::V0;
# HARNESS-DURATION-SHORT

use Test2::Harness2::Runner::State;

# Bypass the heavy init (settings/workdir/resources) -- task_stage only reads
# preloader / stage_map / stage_lifecycle.
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

    is($state->task_stage({use_preload => 1, no_preload => 1}), 'NOPRELOAD',
        "no_preload => 1 => the synthetic NOPRELOAD stage (even with use_preload)");

    is($state->task_stage({use_preload => 1, no_preload => 1, preload_list => ['A']}),
        'NOPRELOAD', "no_preload wins over any preload_list");
};

# Regression: when an in-runner preloader is present (the no-preload run path, or a
# below-threshold preload), it OWNS the NOPRELOAD-vs-default decision. A no_preload
# task in a run with no staged preload must resolve to the runner's own 'default'
# stage -- NOT a synthetic 'NOPRELOAD' bucket the runner never schedules (which
# would leave the task pending forever and hang winddown).
subtest preloader_owns_nopreload_fallback => sub {
    {
        package FakePreloader;
        sub new { bless {}, shift }
        # Mimics Runner::Preloader::task_stage with no staged preload / below
        # threshold: every task (including a NOPRELOAD 'wants') resolves to default.
        sub task_stage { return 'default' }
    }

    my $state = FakeState->new(preloader => FakePreloader->new, stage_map => undef);

    is($state->task_stage({use_preload => 0}), 'default',
        "no_preload task delegates to the preloader, which forks it in 'default'");

    is($state->task_stage({use_preload => 1}), 'default',
        "a normal task also delegates to the preloader");
};

# Chunk 23: stage selection is decided client-side from the three preload fields
# (no_preload / require_preload / preload_list) resolved against the local stage
# map + live lifecycle. task_stage is the bucketing key.
subtest field_based_selection => sub {
    my $state = FakeState->new(
        preloader => undef,
        stage_map => {
            default => {default => 1},
            ALPHA   => {default => 0},
            BETA    => {default => 0},
        },
    );

    # No live stages yet: everything mapped is 'absent' until lifecycle says
    # otherwise, so a listed-but-not-mapped stage falls through; mapped stages are
    # waitable.
    $state->stage_ready('default');

    is($state->task_stage({use_preload => 1, preload_list => []}), 'default',
        "empty preload_list => default stage");

    is($state->task_stage({use_preload => 1, preload_list => ['ALPHA', 'BETA']}), 'ALPHA',
        "first listed stage that EXISTS in the map is bucketed (waiting) when none up");

    # Bring BETA up: the first UP listed stage wins, even though ALPHA precedes it.
    $state->stage_ready('BETA');
    is($state->task_stage({use_preload => 1, preload_list => ['ALPHA', 'BETA']}), 'BETA',
        "first listed stage that is UP wins over an earlier not-up preference");

    # ALPHA up too: now the earlier preference wins.
    $state->stage_ready('ALPHA');
    is($state->task_stage({use_preload => 1, preload_list => ['ALPHA', 'BETA']}), 'ALPHA',
        "with both up, the first preference wins");
};

subtest absent_and_down_listed_stages => sub {
    my $state = FakeState->new(
        preloader => undef,
        stage_map => {default => {default => 1}, ALPHA => {default => 0}},
    );
    $state->stage_ready('default');
    $state->stage_ready('ALPHA');
    $state->stage_down('ALPHA');

    is($state->task_stage({use_preload => 1, preload_list => ['NOPE']}), 'default',
        "a listed stage absent from the map => fall to default (it is permanent)");

    is($state->task_stage({use_preload => 1, preload_list => ['ALPHA']}), 'default',
        "a listed stage marked 'down' => fall to default (permanent)");

    is($state->task_stage({use_preload => 1, preload_list => ['ALPHA', 'NOPE']}), 'default',
        "all listed stages gone => default");
};

subtest legacy_stage_field => sub {
    my $state = FakeState->new(
        preloader => undef,
        stage_map => {default => {default => 1}, MOOSE => {default => 0}},
    );
    $state->stage_ready('default');

    is($state->task_stage({use_preload => 1, stage => 'MOOSE'}), 'MOOSE',
        "legacy 'stage' field with no preload_list still routes (mapped => waitable)");

    is($state->task_stage({use_preload => 1, stage => undef}), 'default',
        "no directive => the map's default stage");
};

done_testing;
