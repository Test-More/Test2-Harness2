use Test2::V0;
use v5.38;

use Test2::Harness2::Runner::Monitor;

# The runner monitor folds a harness_system facet (the sampler's load snapshot,
# ARCHITECTURE.md §4.4) into a single, latest-wins system_load slot. It is a global
# singleton, not a lifecycle entity: it is replaced (not accumulated), exposed via
# system_load(), and carried in BOTH the global and run-scoped snapshots so a late
# subscriber gets current load.

sub sys_payload ($load) { return {facet_data => {harness_system => $load}} }

subtest stores_and_replaces => sub {
    my $mon = Test2::Harness2::Runner::Monitor->new;

    is($mon->system_load, undef, "no load before any message");

    $mon->feed(sys_payload({cpu_pct => 45, mem_pct => 10}));
    is($mon->system_load, {cpu_pct => 45, mem_pct => 10}, "stores the first snapshot");

    $mon->feed(sys_payload({cpu_pct => 60, mem_pct => 15}));
    is($mon->system_load, {cpu_pct => 60, mem_pct => 15}, "latest snapshot replaces the prior one (not accumulated)");
};

subtest snapshot_carries_system_load => sub {
    my $mon = Test2::Harness2::Runner::Monitor->new;
    $mon->feed(sys_payload({cpu_pct => 80, mem_pct => 20}));

    my $global = $mon->snapshot;
    is($global->{system_load}, {cpu_pct => 80, mem_pct => 20}, "global snapshot carries system_load");

    # System load is run-less / global, so a run-scoped snapshot carries it too.
    my $scoped = $mon->snapshot('RUN-1');
    is($scoped->{system_load}, {cpu_pct => 80, mem_pct => 20}, "run-scoped snapshot also carries system_load");
};

subtest apply_snapshot_round_trips => sub {
    my $mon = Test2::Harness2::Runner::Monitor->new;
    $mon->feed(sys_payload({cpu_pct => 35, mem_pct => 5}));

    my $mirror = Test2::Harness2::Runner::Monitor->new;
    $mirror->apply_snapshot($mon->snapshot);

    is($mirror->system_load, {cpu_pct => 35, mem_pct => 5}, "a subscriber's mirror gets current load from the snapshot");
};

done_testing;
