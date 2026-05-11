use Test2::V0;

use Test2::Harness2::Resource::Throttle;

sub _make_throttle {
    my (%p) = @_;
    return Test2::Harness2::Resource::Throttle->new(
        cap    => $p{cap}    // 5,
        window => $p{window} // 2,
        name   => $p{name}   // 'throttle',
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
    local $Test2::Harness2::Resource::Throttle::CLOCK = sub { $now };

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
    local $Test2::Harness2::Resource::Throttle::CLOCK = sub { $now };

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
    local $Test2::Harness2::Resource::Throttle::CLOCK = sub { $now };

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

done_testing;
