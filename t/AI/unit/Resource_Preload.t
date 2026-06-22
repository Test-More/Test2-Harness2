use Test2::V0;
# HARNESS-DURATION-SHORT

use Test2::Harness2::Runner::State;
use Test2::Harness2::Runner::Resource::Preload;

# A State with the heavy init bypassed -- the preload Resource only reads
# stage_map / stage_is_up / stage_state / task_preload_list / task_stage off it.
{
    package FakeState;
    our @ISA = ('Test2::Harness2::Runner::State');
    sub init {}
}

sub build_resource {
    my %map_args = @_;
    my $state = FakeState->new(preloader => undef, stage_map => $map_args{stage_map});

    # Drive lifecycle the same way set_stage_map / stage_ready would.
    $state->set_stage_map($map_args{stage_map}) if $map_args{stage_map};
    $state->stage_ready($_)      for @{$map_args{up}        || []};
    $state->stage_down($_)       for @{$map_args{down}      || []};
    $state->stage_restarting($_) for @{$map_args{restarting} || []};

    my $res = Test2::Harness2::Runner::Resource::Preload->new(settings => undef, state => $state);
    return ($res, $state);
}

my $MAP = {default => {default => 1}, ALPHA => {default => 0}, BETA => {default => 0}};

subtest no_preload_not_gated => sub {
    my ($res) = build_resource(stage_map => $MAP, up => ['default']);

    is($res->available({use_preload => 0}), 1, "no use_preload => available (not gated)");
    is($res->available({use_preload => 1, no_preload => 1}), 1, "no_preload => available (not gated)");
};

subtest empty_or_no_map => sub {
    my ($res) = build_resource(stage_map => undef);
    is($res->available({use_preload => 1, preload_list => ['ALPHA']}), 1,
        "no stage map at all => available (nothing to gate)");

    my ($res2) = build_resource(stage_map => $MAP, up => ['default']);
    is($res2->available({use_preload => 1, preload_list => []}), 1,
        "empty preload_list => available (falls to default)");
};

subtest up_listed_stage_available => sub {
    my ($res) = build_resource(stage_map => $MAP, up => ['default', 'BETA']);

    is($res->available({use_preload => 1, preload_list => ['ALPHA', 'BETA']}), 1,
        "a listed stage is up (BETA) => available even though ALPHA is not");
};

subtest waiting_when_starting => sub {
    # ALPHA present in the map (=> starting) but not up.
    my ($res) = build_resource(stage_map => $MAP, up => ['default']);

    is($res->available({use_preload => 1, preload_list => ['ALPHA']}), 0,
        "listed stage present but not up (starting) => 0 (wait)");

    my ($res2) = build_resource(stage_map => $MAP, up => ['default'], restarting => ['ALPHA']);
    is($res2->available({use_preload => 1, preload_list => ['ALPHA']}), 0,
        "listed stage restarting => 0 (wait)");
};

subtest require_miss_is_negative => sub {
    # NOPE is absent from the map; ALPHA is explicitly down. Both permanent.
    my ($res) = build_resource(stage_map => $MAP, up => ['default'], down => ['ALPHA']);

    is($res->available({use_preload => 1, require_preload => 1, preload_list => ['NOPE']}), -1,
        "require + listed stage absent from map => -1 (skip/fail)");

    is($res->available({use_preload => 1, require_preload => 1, preload_list => ['ALPHA']}), -1,
        "require + listed stage down => -1 (skip/fail)");

    is($res->available({use_preload => 1, require_preload => 1, preload_list => ['NOPE', 'ALPHA']}), -1,
        "require + all listed gone => -1");
};

subtest advisory_miss_falls_to_default => sub {
    my ($res) = build_resource(stage_map => $MAP, up => ['default'], down => ['ALPHA']);

    is($res->available({use_preload => 1, require_preload => 0, preload_list => ['NOPE']}), 1,
        "advisory + listed stage gone => 1 (falls to default), never -1");

    is($res->available({use_preload => 1, require_preload => 0, preload_list => ['ALPHA']}), 1,
        "advisory + listed stage down => 1 (falls to default)");
};

subtest startup_timeout_safeguard => sub {
    require Getopt::Yath::Settings;

    # ALPHA is present in the map but not up (restarting). With a 5s per-stage
    # startup safeguard configured and ALPHA backdated so it has been coming up for
    # 100s, the safeguard treats it as permanently gone instead of waiting forever.
    my $LC = Test2::Harness2::Runner::State->STAGE_LIFECYCLE;

    my $build = sub {
        my $state = FakeState->new(preloader => undef, stage_map => $MAP);
        $state->set_stage_map($MAP);
        $state->stage_ready('default');
        $state->stage_restarting('ALPHA');    # present but not up
        $state->{$LC}{ALPHA}{stamp} -= 100;    # make it look stuck

        my $settings = Getopt::Yath::Settings->new(runner => {preload_stage_startup_timeout => 5});
        return Test2::Harness2::Runner::Resource::Preload->new(settings => $settings, state => $state);
    };

    my $res = $build->();
    is($res->available({use_preload => 1, require_preload => 1, preload_list => ['ALPHA']}), -1,
        "required stage stuck starting past the safeguard => -1 (skip/fail)");

    my $res2 = $build->();
    is($res2->available({use_preload => 1, require_preload => 0, preload_list => ['ALPHA']}), 1,
        "advisory stage stuck starting past the safeguard => 1 (falls to default)");

    # Without the safeguard (timeout 0, the default), the same stuck stage is waited on.
    my $state = FakeState->new(preloader => undef, stage_map => $MAP);
    $state->set_stage_map($MAP);
    $state->stage_ready('default');
    $state->stage_restarting('ALPHA');
    $state->{$LC}{ALPHA}{stamp} -= 100;
    my $no_timeout = Test2::Harness2::Runner::Resource::Preload->new(settings => undef, state => $state);
    is($no_timeout->available({use_preload => 1, require_preload => 1, preload_list => ['ALPHA']}), 0,
        "no safeguard configured => still waits (0) on a long-starting stage");
};

subtest assign_records_chosen_stage => sub {
    my ($res) = build_resource(stage_map => $MAP, up => ['default', 'ALPHA']);

    my $state = {args => [], env_vars => {}};
    $res->assign({use_preload => 1, preload_list => ['ALPHA']}, $state);
    is($state->{record}, {stage => 'ALPHA'}, "assign records the chosen (up) stage");

    my $state2 = {args => [], env_vars => {}};
    $res->assign({use_preload => 0}, $state2);
    is($state2->{record}, undef, "no_preload task records no stage");
};

done_testing;
