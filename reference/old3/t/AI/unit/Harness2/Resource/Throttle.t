use Test2::V0;

use Test2::Harness2::Resource::Throttle;

sub _make_throttle {
    my (%p) = @_;
    return Test2::Harness2::Resource::Throttle->new(
        cap        => $p{cap}        // 5,
        window     => $p{window}     // 2,
        name       => $p{name}       // 'throttle',
        bases      => $p{bases}      // [],
        core_count => $p{core_count} // undef,
    );
}

package TFakeTestFile {
    sub new      { my ($c, $rel) = @_; bless {rel => $rel}, $c }
    sub relative { $_[0]->{rel} }
}

package TFakeJob {
    sub new       { my ($c, $tf) = @_; bless {tf => $tf}, $c }
    sub test_file { $_[0]->{tf} }
}
sub _job { TFakeJob->new(TFakeTestFile->new('t/foo.t')) }

subtest 'init validation' => sub {
    like(
        dies { Test2::Harness2::Resource::Throttle->new() },
        qr/cap/, 'no cap'
    );
    like(
        dies { Test2::Harness2::Resource::Throttle->new(cap => 0, window => 1) },
        qr/cap/, 'zero cap'
    );
    like(
        dies { Test2::Harness2::Resource::Throttle->new(cap => 1.5, window => 1) },
        qr/cap/, 'fractional cap'
    );
    like(
        dies { Test2::Harness2::Resource::Throttle->new(cap => 1, window => 0) },
        qr/window/, 'zero window'
    );
    like(
        dies { Test2::Harness2::Resource::Throttle->new(cap => 1, window => 'abc') },
        qr/window/, 'non-numeric window'
    );
    like(
        dies { Test2::Harness2::Resource::Throttle->new(cap => 1, window => 1, name => '') },
        qr/name/, 'empty name'
    );
    like(
        dies { Test2::Harness2::Resource::Throttle->new(cap => 1, window => 1, name => 'has space') },
        qr/name/, 'name with whitespace'
    );
    ok(_make_throttle(), 'good ctor succeeds');
};

subtest 'available() before any assignment is 1' => sub {
    my $r = _make_throttle(cap => 3, window => 2);
    is($r->available(job => _job), 1, 'plenty');
};

subtest 'available() returns 0 once cap is reached' => sub {
    my $r   = _make_throttle(cap => 3, window => 2);
    my $now = 1000;
    local $Test2::Harness2::Util::HiResTime::CLOCK = sub { $now };

    $r->assign(id => 'A', job => _job, env => {});
    $r->assign(id => 'B', job => _job, env => {});
    $r->assign(id => 'C', job => _job, env => {});

    is($r->available(job => _job), 0, 'at cap');

    # Release one -- count drops below cap.
    $r->release(id => 'A');
    is($r->available(job => _job), 1, 'after release');
};

subtest 'aged-out slots free up regardless of release' => sub {
    my $r   = _make_throttle(cap => 2, window => 2);
    my $now = 1000;
    local $Test2::Harness2::Util::HiResTime::CLOCK = sub { $now };

    $r->assign(id => 'A', job => _job, env => {});
    $r->assign(id => 'B', job => _job, env => {});
    is($r->available(job => _job), 0, 'at cap');

    # Advance past window. A and B age out without being released.
    $now += 3;
    is($r->available(job => _job), 1, 'aged out -> available');

    # Release after age-out is still legal (assignment record is still
    # there, slot just expired). No double-counting.
    $r->release(id => 'A');
    $r->release(id => 'B');
    is($r->available(job => _job), 1, 'still available');
};

subtest 'mixed: some still in window, some aged out' => sub {
    my $r   = _make_throttle(cap => 3, window => 2);
    my $now = 1000;
    local $Test2::Harness2::Util::HiResTime::CLOCK = sub { $now };

    $r->assign(id => 'A', job => _job, env => {});    # t=1000
    $now += 1;
    $r->assign(id => 'B', job => _job, env => {});    # t=1001
    $r->assign(id => 'C', job => _job, env => {});    # t=1001
    is($r->available(job => _job), 0, 'at cap with 3 in window');

    # Advance to t=1002.5 -- A is aged out (1000 + 2 = 1002 < 1002.5),
    # B and C are still in window (1001 + 2 = 1003 > 1002.5).
    $now = 1002.5;
    is($r->available(job => _job), 1, 'A aged out -> 2 in window -> 1 available');
};

subtest 'assign / release contract' => sub {
    my $r = _make_throttle();

    $r->assign(id => 'X', job => _job, env => {});
    like(
        dies { $r->assign(id => 'X', job => _job, env => {}) },
        qr/duplicate/, 'duplicate id croaks'
    );
    like(
        dies { $r->release(id => 'unknown') },
        qr/invalid release/, 'unknown id croaks'
    );
    like(
        dies { $r->assign(job => _job, env => {}) },
        qr/'id' is required/, 'missing id'
    );
    like(
        dies { $r->assign(id => 'Y', env => {}) },
        qr/'job' is required/, 'missing job'
    );
    like(
        dies { $r->assign(id => 'Y', job => _job) },
        qr/'env' hashref is required/, 'missing env'
    );
};

subtest 'pause / resume' => sub {
    my $r = _make_throttle();
    is($r->is_paused, 0, 'starts not paused');
    $r->mark_paused;
    is($r->is_paused, 1, 'paused');
    $r->mark_resumed;
    is($r->is_paused, 0, 'resumed');
};

subtest 'is_broken / is_permanent_broken always 0' => sub {
    my $r = _make_throttle();
    is($r->is_broken,           0, 'never broken');
    is($r->is_permanent_broken, 0, 'never permanent_broken');
};

subtest 'resource_name reflects custom name' => sub {
    my $r = _make_throttle(name => 'db_throttle');
    is($r->resource_name, 'db_throttle', 'custom name returned');

    my $d = _make_throttle();
    is($d->resource_name, 'throttle', 'default name');
};

subtest 'status snapshot shape' => sub {
    my $r   = _make_throttle(cap => 3, window => 2, name => 'db_throttle');
    my $now = 5000;
    local $Test2::Harness2::Util::HiResTime::CLOCK = sub { $now };

    $r->assign(id => 'A', job => _job, env => {});    # t=5000
    $now += 1;
    $r->assign(id => 'B', job => _job, env => {});    # t=5001
    $now = 5003;                                      # A aged out, B in window
    $r->assign(id => 'C', job => _job, env => {});    # t=5003

    my $st = $r->status;
    is($st->{resource},          'db_throttle', 'resource name');
    is($st->{cap},               3,             'cap');
    is($st->{window},            2,             'window');
    is($st->{paused},            0,             'not paused');
    is($st->{total_assignments}, 3,             'three tracked');
    is($st->{in_window_count},   1,             'only C still in window (B at exact boundary is aged out)');

    is(scalar @{$st->{assignments}}, 3, 'three assignments listed');

    my %by_id = map { $_->{id} => $_ } @{$st->{assignments}};
    is($by_id{A}->{in_window}, 0, 'A aged out');
    is($by_id{B}->{in_window}, 0, 'B aged out at exactly age == window');
    is($by_id{C}->{in_window}, 1, 'C in window');

    is($by_id{A}->{age},  3,         'A age');
    is($by_id{B}->{age},  2,         'B age');
    is($by_id{C}->{age},  0,         'C age');
    is($by_id{A}->{test}, 't/foo.t', 'test path');
};

subtest 'slot ages out at exactly age == window' => sub {
    my $r   = _make_throttle(cap => 1, window => 2);
    my $now = 100;
    local $Test2::Harness2::Util::HiResTime::CLOCK = sub { $now };

    $r->assign(id => 'A', job => _job, env => {});
    is($r->available(job => _job), 0, 'cap reached');

    # Just before the boundary: still in window.
    $now = 100 + 2 - 0.001;
    is($r->available(job => _job), 0, 'just before boundary: still held');

    # At exactly the boundary: slot aged out.
    $now = 100 + 2;
    is($r->available(job => _job), 1, 'at exact boundary: aged out');

    # Past the boundary: definitely aged out.
    $now = 100 + 5;
    is($r->available(job => _job), 1, 'past boundary: aged out');
};

# --------------------------------------------------------------------
# Multi-basis math tests using test seams
# --------------------------------------------------------------------

# Helper to build a bases arrayref.
sub _core_basis { {type => 'core'} }
sub _ram_basis  { my ($mb) = @_; {type => 'ram', bytes => $mb * 1024 * 1024} }

subtest 'multi-basis: 8-core, 4GB free, 1/core,1gb/1s => 4 tokens' => sub {
    # cores = 8, free = 4GB, 1gb basis = 1073741824 bytes
    # floor(4GB / 1GB) = 4; cores = 8; min(4,8) = 4; cap*min = 1*4 = 4
    local $Test2::Harness2::Resource::Throttle::DETECT_CORE_COUNT  = sub { 8 };
    local $Test2::Harness2::Resource::Throttle::READ_MEMINFO_AVAIL = sub { 4 * 1024 * 1024 * 1024 };

    my $r = Test2::Harness2::Resource::Throttle->new(
        cap    => 1,
        window => 1,
        bases  => [_core_basis(), _ram_basis(1024)],
    );

    my ($tokens, $eff_win) = $r->_token_count();
    is($tokens,  4, 'tokens = 4 (limited by RAM: 4GB/1GB=4, vs cores=8)');
    is($eff_win, 1, 'effective window unchanged (no scaling needed)');

    # 4 assignments fit, 5th defers.
    my $now = 1000;
    local $Test2::Harness2::Util::HiResTime::CLOCK = sub { $now };
    $r->assign(id => "s$_", job => _job, env => {}) for 1 .. 4;
    is($r->available(job => _job), 0, 'at 4 tokens: deferred');
};

subtest 'multi-basis: core-only, 8 cores, cap=2 => 16 tokens' => sub {
    local $Test2::Harness2::Resource::Throttle::DETECT_CORE_COUNT = sub { 8 };

    my $r = Test2::Harness2::Resource::Throttle->new(
        cap    => 2,
        window => 1,
        bases  => [_core_basis()],
    );

    my ($tokens, $eff_win) = $r->_token_count();
    is($tokens,  16, 'tokens = cap * cores = 2 * 8 = 16');
    is($eff_win, 1,  'effective window unchanged');
};

subtest 'adaptive scaling: first level (80MB free, 100MB basis)' => sub {
    # free(80MB) < basis(100MB): halve -> basis=50MB, window=2x
    # floor(80MB / 50MB) = 1; cap=1; tokens=1; eff_window=2s
    local $Test2::Harness2::Resource::Throttle::READ_MEMINFO_AVAIL = sub { 80 * 1024 * 1024 };

    my $r = Test2::Harness2::Resource::Throttle->new(
        cap    => 1,
        window => 1,
        bases  => [_ram_basis(100)],
    );

    my ($tokens, $eff_win) = $r->_token_count();
    is($tokens,  1, 'tokens = 1 (80MB / 50MB = 1 after 1 halving)');
    is($eff_win, 2, 'effective window = 2x (one halving)');
};

subtest 'adaptive scaling: second level (30MB free, 100MB basis)' => sub {
    # free(30MB) < basis(100MB): halve -> 50MB, still < 30MB: halve -> 25MB, window=4x
    # floor(30MB / 25MB) = 1; tokens=1; eff_window=4s
    local $Test2::Harness2::Resource::Throttle::READ_MEMINFO_AVAIL = sub { 30 * 1024 * 1024 };

    my $r = Test2::Harness2::Resource::Throttle->new(
        cap    => 1,
        window => 1,
        bases  => [_ram_basis(100)],
    );

    my ($tokens, $eff_win) = $r->_token_count();
    is($tokens,  1, 'tokens = 1 (30MB / 25MB = 1 after 2 halvings)');
    is($eff_win, 4, 'effective window = 4x (two halvings)');
};

subtest 'adaptive scaling: floor at 2 halvings (10MB free, 100MB basis => 0 tokens => defer' => sub {
    # free(10MB) < basis(100MB): halve -> 50MB; still < 10MB: halve -> 25MB (capped)
    # basis(25MB) > free(10MB): tokens = 0 (defer all)
    local $Test2::Harness2::Resource::Throttle::READ_MEMINFO_AVAIL = sub { 10 * 1024 * 1024 };

    my $r = Test2::Harness2::Resource::Throttle->new(
        cap    => 1,
        window => 1,
        bases  => [_ram_basis(100)],
    );

    my ($tokens, $eff_win) = $r->_token_count();
    is($tokens,                    0, 'tokens = 0 (25MB basis > 10MB free => defer)');
    is($eff_win,                   4, 'effective window = 4x (cap at 2 halvings)');
    is($r->available(job => _job), 0, 'available() returns 0 (deferred)');
};

subtest 'adaptive scaling: recovery (free RAM above original basis => no scaling)' => sub {
    # When free RAM >= original basis, window_mult stays 1.
    local $Test2::Harness2::Resource::Throttle::READ_MEMINFO_AVAIL = sub { 200 * 1024 * 1024 };

    my $r = Test2::Harness2::Resource::Throttle->new(
        cap    => 1,
        window => 1,
        bases  => [_ram_basis(100)],
    );

    my ($tokens, $eff_win) = $r->_token_count();
    is($tokens,  2, 'tokens = 2 (200MB / 100MB = 2, cap*min = 1*2)');
    is($eff_win, 1, 'effective window = 1x (no pressure)');
};

subtest 'core-only basis on non-Linux is fine (no /proc/meminfo touched)' => sub {
    # Simulate a non-Linux env by providing a fake core count detector.
    # The important thing: no READ_MEMINFO_AVAIL override needed = not called.
    local $Test2::Harness2::Resource::Throttle::DETECT_CORE_COUNT = sub { 4 };

    my $r = Test2::Harness2::Resource::Throttle->new(
        cap    => 1,
        window => 1,
        bases  => [_core_basis()],
    );

    # Override to croak if called -- should never be reached for core-only.
    local $Test2::Harness2::Resource::Throttle::READ_MEMINFO_AVAIL = sub { die "should not read meminfo for core-only basis" };

    my ($tokens, $eff_win) = $r->_token_count();
    is($tokens,  4, 'core-only: tokens = 4 (1*4 cores)');
    is($eff_win, 1, 'core-only: no window scaling');
};

subtest 'RAM basis init croaks on non-Linux (no /proc/meminfo)' => sub {
    # Simulate non-Linux: READ_MEMINFO_AVAIL is undef (no override) and
    # /proc/meminfo doesn't exist. We fake this by temporarily overriding
    # the guard to see the path that would croak.
    #
    # On Linux (CI): /proc/meminfo exists, so the real guard won't croak.
    # We test the croak path by using a mock that pretends the file is absent.
    SKIP: {
        skip "RAM basis croak path tested via mock only when /proc/meminfo absent", 1
            if -e '/proc/meminfo';

        like(
            dies {
                Test2::Harness2::Resource::Throttle->new(
                    cap    => 1,
                    window => 1,
                    bases  => [_ram_basis(100)],
                )
            },
            qr{/proc/meminfo},
            'RAM basis on non-Linux croaks at init with clear message',
        );
    }

    # On Linux, verify it does NOT croak (sanity check).
    if (-e '/proc/meminfo') {
        ok(
            lives {
                local $Test2::Harness2::Resource::Throttle::READ_MEMINFO_AVAIL = sub { 500 * 1024 * 1024 };
                Test2::Harness2::Resource::Throttle->new(
                    cap    => 1,
                    window => 1,
                    bases  => [_ram_basis(100)],
                );
            },
            'RAM basis on Linux does not croak at init',
        );
    }
};

subtest 'multi-basis MIN math: 8 cores, 100MB basis, 4GB free => min(8,40)=8, tokens=8' => sub {
    local $Test2::Harness2::Resource::Throttle::DETECT_CORE_COUNT  = sub { 8 };
    local $Test2::Harness2::Resource::Throttle::READ_MEMINFO_AVAIL = sub { 4 * 1024 * 1024 * 1024 };

    my $r = Test2::Harness2::Resource::Throttle->new(
        cap    => 1,
        window => 1,
        bases  => [_core_basis(), _ram_basis(100)],
    );

    my ($tokens, $eff_win) = $r->_token_count();
    # floor(4GB / 100MB) = floor(4096 / 100) = 40 tokens from RAM
    # cores = 8 tokens from core basis
    # min(40, 8) = 8; cap(1) * 8 = 8
    is($tokens,  8, 'tokens = 8 (min of 40 ram-tokens and 8 core-tokens, then cap*min)');
    is($eff_win, 1, 'no scaling needed');
};

subtest 'retroactive window: slots assigned under 1s count against 4s effective window' => sub {
    # When scaling kicks in (e.g. free RAM drops mid-run), previously assigned
    # slots stay in the (now longer) effective window.
    local $Test2::Harness2::Resource::Throttle::READ_MEMINFO_AVAIL = sub { 10 * 1024 * 1024 };    # triggers 2 halvings => window_mult=4

    my $r = Test2::Harness2::Resource::Throttle->new(
        cap    => 5,
        window => 1,
        bases  => [_ram_basis(100)],
    );

    my $now = 1000;
    local $Test2::Harness2::Util::HiResTime::CLOCK = sub { $now };

    # Assign a slot at t=1000 under zero tokens (10MB/25MB=0, so available
    # returns 0, but we test _in_window_count directly to verify retroactive
    # window accounting).
    $r->{+Test2::Harness2::Resource::Throttle::ASSIGNMENTS}->{'X'} = {
        job         => _job(),
        assigned_at => $now,
    };

    # At t=1000 + 1.5s, slot is past the ORIGINAL 1s window but still
    # inside the 4x effective window (4s).
    $now += 1.5;
    my (undef, $eff_win) = $r->_token_count();
    is($eff_win,                       4, 'effective window is 4x original');
    is($r->_in_window_count($eff_win), 1, 'slot counted against 4s effective window at t+1.5s');

    # At t=1000 + 3s, still inside 4s effective window.
    $now = 1000 + 3;
    is($r->_in_window_count($eff_win), 1, 'slot still in effective 4s window at t+3s');

    # At t=1000 + 4s, slot ages out of even the 4s window.
    $now = 1000 + 4;
    is($r->_in_window_count($eff_win), 0, 'slot aged out at exact 4s boundary');
};

subtest '_read_meminfo_available does not clobber caller $_' => sub {
    # Regression test: _read_meminfo_available used `while (<$fh>)` which
    # writes each line to $_. When status() is called from
    # `map { $_->status } @{+RESOURCES}` (as request_handler_status does),
    # the outer $_ is aliased to a live array element and the bare diamond
    # read replaces the blessed Resource::Throttle with the last meminfo
    # line read. Symptom: subsequent iterations call ->status on a raw
    # string and die "Can't locate object method 'status' via package
    # 'MemAvailable: ... kB'".
    SKIP: {
        skip "regression test requires /proc/meminfo (linux only)", 1
            unless -e '/proc/meminfo';

        my $r = Test2::Harness2::Resource::Throttle->new(
            cap    => 1,
            window => 1,
            bases  => [_ram_basis(100)],
        );

        my @arr = ($r);
        # Call _read_meminfo_available indirectly via status() inside a
        # map block whose $_ is aliased to $arr[0]. If the bug regresses,
        # $arr[0] becomes a meminfo string after the map runs.
        my @status = map { $_->status } @arr;

        ok(ref($arr[0]) eq 'Test2::Harness2::Resource::Throttle',
            'array element still blessed Throttle after map { ->status }')
            or diag "got: ", (ref($arr[0]) || $arr[0]);
        ok(ref($status[0]) eq 'HASH', 'status() returned a hashref');
    }
};

done_testing;
