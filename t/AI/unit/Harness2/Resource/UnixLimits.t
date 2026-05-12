use Test2::V0;

use Test2::Harness2::Resource::UnixLimits;

plan skip_all => "Linux only" unless $^O eq 'linux';

# Test seams: tests override these to inject deterministic samples.
our (%LIMITS, %STATUS, $FD_COUNT);
no warnings 'redefine';
*Test2::Harness2::Resource::UnixLimits::_read_self_limits = sub { \%LIMITS };
*Test2::Harness2::Resource::UnixLimits::_read_self_status = sub { \%STATUS };
*Test2::Harness2::Resource::UnixLimits::_count_self_fd    = sub { $FD_COUNT };
use warnings;

package TFakeTestFile {
    sub new      { bless {rel => $_[1]}, $_[0] }
    sub relative { $_[0]->{rel} }
}

package TFakeJob {
    sub new       { bless {tf => $_[1]}, $_[0] }
    sub test_file { $_[0]->{tf} }
}
sub _job { TFakeJob->new(TFakeTestFile->new('t/foo.t')) }

sub _make {
    my (%p) = @_;
    return Test2::Harness2::Resource::UnixLimits->new(
        nproc  => $p{nproc}  // {kind => 'pct', value => 10},
        nofile => $p{nofile} // {kind => 'pct', value => 10},
        ($p{as}              ? (as              => $p{as})              : ()),
        ($p{utilize_percent} ? (utilize_percent => $p{utilize_percent}) : ()),
        ($p{name}            ? (name            => $p{name})            : ()),
    );
}

subtest 'init validation' => sub {
    ok(_make(), 'good ctor');
    like(
        dies { _make(nproc => {kind => 'wat', value => 1}) },
        qr/nproc/, 'bad kind'
    );
};

subtest 'nproc pct under threshold' => sub {
    local %LIMITS   = (nproc   => 1000, nofile => 1024, as => 0);
    local %STATUS   = (Threads => 100,  VmSize => 0);
    local $FD_COUNT = 50;
    my $r = _make(nproc => {kind => 'pct', value => 10});    # need 10% free
    is($r->is_temporarily_unavailable, 0, '900 free > 100 threshold (10% of 1000)');
};

subtest 'nproc pct over threshold' => sub {
    local %LIMITS   = (nproc   => 1000, nofile => 1024, as => 0);
    local %STATUS   = (Threads => 950,  VmSize => 0);
    local $FD_COUNT = 50;
    my $r = _make(nproc => {kind => 'pct', value => 10});    # need 10% free
    is($r->is_temporarily_unavailable, 1, '50 free < 100 threshold');
};

subtest 'nofile count threshold' => sub {
    local %LIMITS   = (nproc   => 1000, nofile => 1024, as => 0);
    local %STATUS   = (Threads => 100,  VmSize => 0);
    local $FD_COUNT = 1000;
    my $r = _make(nofile => {kind => 'count', value => 50});    # need 50 free
    is($r->is_temporarily_unavailable, 1, '24 free < 50 threshold');
};

subtest 'as opt-in works' => sub {
    local %LIMITS   = (nproc   => 1000, nofile => 1024, as => 1024**3);
    local %STATUS   = (Threads => 100,  VmSize => 900 * 1024);    # VmSize is kB; 900*1024 bytes = 900MB
    local $FD_COUNT = 50;
    # AS=1GB, used=900MB, free=124MB. Need 200MB free.
    my $r = _make(as => {kind => 'bytes', value => 200 * 1024**2});
    is($r->is_temporarily_unavailable, 1, 'AS triggers');
};

subtest 'utilize-derived layered with explicit (more conservative wins)' => sub {
    local %LIMITS   = (nproc   => 1000, nofile => 1024, as => 0);
    local %STATUS   = (Threads => 100,  VmSize => 0);
    local $FD_COUNT = 50;

    # nproc pct=5 (need 50 free) layered with utilize=80 (need 20% = 200 free).
    # Effective: max(50, 200) = 200. Current free = 900 > 200 -> ok.
    my $r = _make(nproc => {kind => 'pct', value => 5}, utilize_percent => 80);
    is($r->is_temporarily_unavailable, 0, '900 free > max(50, 200)');

    # Bump load. nproc usage 850 -> 150 free. utilize-derived still 200. Defer.
    local %STATUS = (Threads => 850, VmSize => 0);
    is($r->is_temporarily_unavailable, 1, '150 free < 200 (utilize wins)');
};

subtest 'pause / resume' => sub {
    my $r = _make();
    $r->mark_paused;
    is($r->is_paused, 1, 'paused');
    $r->mark_resumed;
    is($r->is_paused, 0, 'resumed');
};

subtest 'status snapshot' => sub {
    local %LIMITS   = (nproc   => 1000, nofile => 1024, as => 0);
    local %STATUS   = (Threads => 100,  VmSize => 0);
    local $FD_COUNT = 50;
    my $r         = _make();
    my $in_flight = 0;
    $r->set_in_flight_ref(\$in_flight);
    my $st = $r->status;
    is($st->{resource}, 'unixlimits', 'name');
    ok($st->{dimensions}{nproc},      'nproc dim present');
    ok($st->{dimensions}{nofile},     'nofile dim present');
    ok(!exists $st->{dimensions}{as}, 'as not present (off by default)');
    is($st->{dimensions}{nproc}{soft_cap}, 1000, 'soft_cap');
    is($st->{dimensions}{nproc}{current},  100,  'current');
};

done_testing;
