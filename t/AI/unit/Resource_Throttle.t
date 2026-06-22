use Test2::V0;
use v5.38;

use Test2::Harness2::Runner::Resource::CPU;
use Test2::Harness2::Runner::Resource::Memory;

# The throttling resources read the runner's shared system-load snapshot (NOT
# /proc inline) and defer new test starts when the monitored subsystem is
# saturated -- but only once the min_concurrent floor is met, so the scheduler
# never stalls. A defer is a transient wait (available => 0), never a permanent
# skip.

# A fake State exposing a settable system_load snapshot.
package FakeState {
    sub new { my ($c, $load) = @_; bless {load => $load}, $c }
    sub system_load { $_[0]->{load} }
    sub set { $_[0]->{load} = $_[1] }
}

subtest cpu_defers_at_threshold => sub {
    my $state = FakeState->new({cpu_pct => 70});
    my $cpu   = Test2::Harness2::Runner::Resource::CPU->new(state => $state, arg => 80);

    is($cpu->utilize_percent, 80, "inline arg sets the threshold");
    is($cpu->resource_name, 'cpu', "default name");

    # 0 in flight: below the min_concurrent floor, never defers.
    is($cpu->available({job_id => 'j1'}), 1, "cpu 70 < 80, available");

    $state->set({cpu_pct => 85});
    is($cpu->available({job_id => 'j1'}), 1, "cpu 85 >= 80 but 0 in flight (floor) -> still available");

    # Take one job; now the floor is met.
    $cpu->record('j1', {});
    is($cpu->in_flight, 1, "tracks one in-flight job");
    is($cpu->available({job_id => 'j2'}), 0, "cpu 85 >= 80 and floor met -> DEFER (0, a wait)");

    $state->set({cpu_pct => 70});
    is($cpu->available({job_id => 'j2'}), 1, "cpu back below threshold -> available again");

    $cpu->release('j1');
    is($cpu->in_flight, 0, "release frees the in-flight slot");
};

subtest cpu_default_threshold => sub {
    my $cpu = Test2::Harness2::Runner::Resource::CPU->new(state => FakeState->new({cpu_pct => 100}));
    is($cpu->utilize_percent, 80, "default threshold is 80 with no arg/settings");
};

subtest cpu_no_snapshot_is_available => sub {
    my $cpu = Test2::Harness2::Runner::Resource::CPU->new(state => FakeState->new(undef), arg => 50);
    $cpu->record('j1', {});
    is($cpu->available({job_id => 'j2'}), 1, "no snapshot yet -> never defers");
};

subtest memory_min_free_pct => sub {
    # min_free 20% of 1000 = 200 bytes. Defer when available < 200.
    my $state = FakeState->new({mem_total => 1000, mem_available => 500});
    my $mem   = Test2::Harness2::Runner::Resource::Memory->new(state => $state, arg => '20%');

    is($mem->min_free, {kind => 'pct', value => 20}, "inline 20% parsed");
    $mem->record('j1', {});

    is($mem->available({job_id => 'j2'}), 1, "free 500 >= 200 threshold -> available");

    $state->set({mem_total => 1000, mem_available => 100});
    is($mem->available({job_id => 'j2'}), 0, "free 100 < 200 threshold -> DEFER");
};

subtest memory_min_free_absolute => sub {
    my $state = FakeState->new({mem_total => 10_000, mem_available => 600});
    my $mem   = Test2::Harness2::Runner::Resource::Memory->new(state => $state, arg => '512kb');

    is($mem->min_free, {kind => 'bytes', value => 512 * 1024}, "absolute 512kb parsed");
    $mem->record('j1', {});

    is($mem->available({job_id => 'j2'}), 0, "free 600 < 512kb threshold -> DEFER");

    $state->set({mem_total => 10_000, mem_available => 512 * 1024 + 1});
    is($mem->available({job_id => 'j2'}), 1, "free above 512kb -> available");
};

subtest memory_default_5pct => sub {
    my $mem = Test2::Harness2::Runner::Resource::Memory->new(state => FakeState->new({mem_total => 1000, mem_available => 1000}));
    is($mem->min_free, {kind => 'pct', value => 5}, "default min_free is 5%");
};

subtest utilizer_floor => sub {
    # The min_concurrent floor: deferral only applies once in_flight >= min.
    my $state = FakeState->new({cpu_pct => 100});

    my $cpu = Test2::Harness2::Runner::Resource::CPU->new(state => $state, arg => 50, min_concurrent => 2);
    is($cpu->min_concurrent, 2, "min_concurrent set");

    is($cpu->available({job_id => 'a'}), 1, "0 in flight (< 2) -> never defers even when saturated");
    $cpu->record('a', {});
    is($cpu->available({job_id => 'b'}), 1, "1 in flight (< 2) -> still under floor, available");
    $cpu->record('b', {});
    is($cpu->available({job_id => 'c'}), 0, "2 in flight (>= 2) and saturated -> DEFER");
};

subtest memory_conservative_wins_with_utilize => sub {
    # Build a settings object that carries --utilize so Memory layers it in.
    require Getopt::Yath::Settings;
    my $settings = Getopt::Yath::Settings->new(runner => {utilize => 90});

    # min_free 1% (10 bytes) vs --utilize 90 -> floor (100-90)=10% (100 bytes). The
    # more conservative (100 bytes) wins.
    my $state = FakeState->new({mem_total => 1000, mem_available => 50});
    my $mem   = Test2::Harness2::Runner::Resource::Memory->new(state => $state, settings => $settings, arg => '1%');
    $mem->record('j1', {});

    is($mem->available({job_id => 'j2'}), 0, "free 50 < the 100-byte --utilize floor -> DEFER (conservative wins)");

    $state->set({mem_total => 1000, mem_available => 150});
    is($mem->available({job_id => 'j2'}), 1, "free 150 above the 100-byte floor -> available");
};

done_testing;
