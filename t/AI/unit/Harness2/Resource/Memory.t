use Test2::V0;

use Test2::Harness2::Resource::Memory;

plan skip_all => "Linux only" unless $^O eq 'linux';

# Stub-out /proc/meminfo reads so tests are deterministic.
my $MEMINFO_BODY = <<'MEMINFO';
MemTotal:        8000000 kB
MemFree:         1000000 kB
MemAvailable:    4000000 kB
MEMINFO

# The resource exposes a small _read_meminfo() seam; tests override it.
no warnings 'redefine';
*Test2::Harness2::Resource::Memory::_read_meminfo = sub { $MEMINFO_BODY };
use warnings;

package TFakeTestFile {
    sub new      { my ($c, $rel) = @_; bless {rel => $rel}, $c }
    sub relative { $_[0]->{rel} }
}

package TFakeJob {
    sub new       { my ($c, $tf) = @_; bless {tf => $tf}, $c }
    sub test_file { $_[0]->{tf} }
}
sub _job { TFakeJob->new(TFakeTestFile->new('t/foo.t')) }

sub _make {
    my (%p) = @_;
    return Test2::Harness2::Resource::Memory->new(
        min_free => $p{min_free} // {kind => 'pct', value => 5},
        ($p{name}            ? (name            => $p{name})            : ()),
        ($p{utilize_percent} ? (utilize_percent => $p{utilize_percent}) : ()),
    );
}

subtest 'init validation' => sub {
    ok(_make(), 'good ctor');
    like(
        dies { Test2::Harness2::Resource::Memory->new(min_free => undef) },
        qr/min_free/, 'undef min_free'
    );
    like(
        dies { Test2::Harness2::Resource::Memory->new(min_free => 'raw') },
        qr/min_free/, 'string min_free without parsing'
    );
    like(
        dies { Test2::Harness2::Resource::Memory->new(min_free => {kind => 'wat'}) },
        qr/min_free/, 'bad kind'
    );
};

subtest 'available always 1; gating in is_temporarily_unavailable' => sub {
    my $r = _make();
    is($r->available(job => _job), 1, 'available is 1');
};

subtest 'is_temporarily_unavailable with pct threshold' => sub {
    # MemTotal 8000000 kB, MemAvailable 4000000 kB. Available is 50% of total.
    my $r = _make(min_free => {kind => 'pct', value => 25});
    is($r->is_temporarily_unavailable, 0, '50% available > 25% threshold');

    my $r2 = _make(min_free => {kind => 'pct', value => 75});
    is($r2->is_temporarily_unavailable, 1, '50% available < 75% threshold');
};

subtest 'is_temporarily_unavailable with bytes threshold' => sub {
    # MemAvailable 4000000 kB = 4 GiB. Threshold 2 GiB -> ok. Threshold 5 GiB -> low.
    my $r = _make(min_free => {kind => 'bytes', value => 2 * 1024**3});
    is($r->is_temporarily_unavailable, 0, '4G available > 2G threshold');

    my $r2 = _make(min_free => {kind => 'bytes', value => 5 * 1024**3});
    is($r2->is_temporarily_unavailable, 1, '4G available < 5G threshold');
};

subtest 'utilize layered: more conservative wins' => sub {
    # MemTotal 8000000 kB, MemAvailable 4000000 kB = 50% available.
    #   min_free pct=10  -> effective 10% (lenient)
    #   utilize=70       -> requires 30% free (more conservative -> wins)
    # 50% > 30% -> still ok.
    my $r = _make(min_free => {kind => 'pct', value => 10}, utilize_percent => 70);
    is($r->is_temporarily_unavailable, 0, '50% > max(10%, 30%) = 30%');

    # Tighten utilize: 90% utilize -> need 10% free. min_free pct=20 wins (more conservative).
    # 50% > 20% -> ok.
    my $r2 = _make(min_free => {kind => 'pct', value => 20}, utilize_percent => 90);
    is($r2->is_temporarily_unavailable, 0, '50% > max(20%, 10%) = 20%');

    # Both conservative: min_free=60% (need 60% free), utilize=70 (need 30% free).
    # max = 60%. 50% < 60% -> low.
    my $r3 = _make(min_free => {kind => 'pct', value => 60}, utilize_percent => 70);
    is($r3->is_temporarily_unavailable, 1, '50% < max(60%, 30%) = 60%');
};

subtest 'pause / resume' => sub {
    my $r = _make();
    is($r->is_paused, 0, 'starts not paused');
    $r->mark_paused;
    is($r->is_paused, 1, 'paused');
    $r->mark_resumed;
    is($r->is_paused, 0, 'resumed');
};

subtest 'assign / release' => sub {
    my $r = _make();
    $r->assign(id => 'A', job => _job, env => {});
    like(
        dies { $r->assign(id => 'A', job => _job, env => {}) },
        qr/duplicate/, 'duplicate id'
    );
    like(
        dies { $r->release(id => 'unknown') },
        qr/invalid release/, 'unknown id'
    );
    $r->release(id => 'A');
};

subtest 'status snapshot' => sub {
    my $r = _make(min_free => {kind => 'pct', value => 25});
    $r->assign(id => 'X', job => _job, env => {});
    my $st = $r->status;
    is($st->{resource},            'memory',                     'name');
    is($st->{min_free},            {kind => 'pct', value => 25}, 'threshold echoed');
    is($st->{mem_total_bytes},     8000000 * 1024,               'total');
    is($st->{mem_available_bytes}, 4000000 * 1024,               'available');
    ok($st->{effective_min_free_bytes} > 0, 'effective threshold computed');
    is($st->{paused},                 0,   'not paused');
    is($st->{total_assignments},      1,   'one assigned');
    is($st->{assignments}->[0]->{id}, 'X', 'id present');
};

done_testing;
