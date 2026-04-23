use strict;
use warnings;
use Test2::V0;

BEGIN {
    my $ipcm_lib = '/home/exodist/projects/IPC-Manager/lib';
    if (-d $ipcm_lib) {
        unshift @INC, $ipcm_lib;
    }
    else {
        plan skip_all => "IPC::Manager lib not found at $ipcm_lib";
    }

    my $ok  = eval { require IPC::Manager; 1 };
    my $err = $@;
    plan skip_all => "IPC::Manager not loadable: $err" unless $ok;
}

use Test2::Harness2;

# ---------------------------------------------------------------------------
# 1. Orderly shutdown state tracking
# ---------------------------------------------------------------------------
subtest 'orderly shutdown state tracking' => sub {
    my $harness = Test2::Harness2->new();

    ok(!$harness->shutdown_requested, 'shutdown_requested starts false');
    ok(!$harness->emergency_shutdown, 'emergency_shutdown starts false');

    $harness->request_shutdown();

    ok($harness->shutdown_requested,  'shutdown_requested is true after request_shutdown');
    ok(!$harness->emergency_shutdown, 'emergency_shutdown remains false after orderly shutdown');

    $harness->workspace->cleanup;
};

# ---------------------------------------------------------------------------
# 2. Heartbeat interval configurable
# ---------------------------------------------------------------------------
subtest 'heartbeat interval configurable' => sub {
    my $harness = Test2::Harness2->new(heartbeat_interval => 5);

    is($harness->heartbeat_interval, 5, 'heartbeat_interval stores provided value');

    $harness->workspace->cleanup;
};

# ---------------------------------------------------------------------------
# 3. Default heartbeat interval
# ---------------------------------------------------------------------------
subtest 'default heartbeat interval' => sub {
    my $harness = Test2::Harness2->new();

    is($harness->heartbeat_interval, 30, 'heartbeat_interval defaults to 30');

    $harness->workspace->cleanup;
};

# ---------------------------------------------------------------------------
# 4. watch_pids includes current PID
# ---------------------------------------------------------------------------
subtest 'watch_pids includes current PID' => sub {
    my $harness = Test2::Harness2->new();

    my $pids = $harness->watch_pids();

    is(ref($pids), 'ARRAY', 'watch_pids returns arrayref');
    ok(scalar @$pids >= 1, 'arrayref contains at least one PID');
    is($pids->[0], $$, 'first element is current PID');

    $harness->workspace->cleanup;
};

# ---------------------------------------------------------------------------
# 5. Emergency shutdown NOT triggered by orderly shutdown
# ---------------------------------------------------------------------------
subtest 'emergency shutdown not triggered by orderly death' => sub {
    my $harness = Test2::Harness2->new();

    $harness->request_shutdown();
    $harness->_handle_scheduler_death(1);    # 1 = orderly

    ok(!$harness->emergency_shutdown, 'emergency_shutdown remains false after orderly death');

    $harness->workspace->cleanup;
};

# ---------------------------------------------------------------------------
# 6. Emergency shutdown triggered by unexpected death
# ---------------------------------------------------------------------------
subtest 'emergency shutdown triggered by unexpected death' => sub {
    my $harness = Test2::Harness2->new();

    # Do NOT call request_shutdown — this is an unexpected death
    $harness->_handle_scheduler_death(0);    # 0 = not orderly

    ok($harness->emergency_shutdown, 'emergency_shutdown is true after unexpected death');

    $harness->workspace->cleanup;
};

done_testing;
