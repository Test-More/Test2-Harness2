use Test2::V0;
use Test2::Harness2::Resource::PipeLimits;

plan skip_all => "Linux only" unless $^O eq 'linux';

# Test seam: override the cap reader so tests can pin /proc/sys/fs/pipe-user-pages-soft.
our $CAP_PAGES = 16384;
no warnings 'redefine';
*Test2::Harness2::Resource::PipeLimits::_read_cap_pages = sub { $CAP_PAGES };
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
    return Test2::Harness2::Resource::PipeLimits->new(
        pipes_per_test    => $p{pipes_per_test}    // 2,
        pipes_per_service => $p{pipes_per_service} // 2,
        service_count     => $p{service_count}     // 0,
        pages_per_pipe    => $p{pages_per_pipe}    // 16,
        headroom          => $p{headroom}          // {kind => 'pct', value => 10},
        ($p{utilize_percent} ? (utilize_percent => $p{utilize_percent}) : ()),
        ($p{name}            ? (name            => $p{name})            : ()),
    );
}

subtest 'init validation' => sub {
    ok(_make(), 'good ctor');
    like(
        dies { _make(headroom => {kind => 'wat', value => 1}) },
        qr/headroom/, 'bad kind'
    );
    like(
        dies { _make(pipes_per_test => -1) },
        qr/pipes_per_test/, 'negative pipes_per_test'
    );
};

subtest 'no tests, no services: plenty free' => sub {
    local $CAP_PAGES = 16384;
    my $r = _make();
    my $in_flight = 0;
    $r->set_in_flight_ref(\$in_flight);
    is($r->is_temporarily_unavailable, 0, 'no usage -> ok');
};

subtest 'tally crosses threshold' => sub {
    # cap=160 pages. service_count=3 * 2 pipes * 16 pages = 96 service pages.
    # 1 test adds 2 pipes * 16 = 32 pages -> 128 used / 160. Free=32.
    # headroom=10% of 160 = 16. 32 - (next test would add 32) = 0 < 16 -> defer.
    local $CAP_PAGES = 160;
    my $r = _make(service_count => 3, headroom => {kind => 'pct', value => 10});
    my $in_flight = 0;
    $r->set_in_flight_ref(\$in_flight);
    is($r->is_temporarily_unavailable, 0, '0 tests: 64 free > 16');

    $in_flight = 1;
    is($r->is_temporarily_unavailable, 1, '1 test in flight: adding another would breach headroom');
};

subtest 'release frees the slot' => sub {
    local $CAP_PAGES = 160;
    my $r = _make(service_count => 3);
    my $in_flight = 1;
    $r->set_in_flight_ref(\$in_flight);
    is($r->is_temporarily_unavailable, 1, 'at limit');
    $in_flight = 0;
    is($r->is_temporarily_unavailable, 0, 'released');
};

subtest 'utilize-derived layered with explicit (more conservative wins)' => sub {
    # cap=200. service_count=0. headroom=count=20 (very lenient).
    # utilize=80 -> derived headroom = (1-0.8)*200 = 40 (more conservative).
    local $CAP_PAGES = 200;
    my $r = _make(headroom => {kind => 'count', value => 20}, utilize_percent => 80);
    my $in_flight = 0;
    $r->set_in_flight_ref(\$in_flight);
    is($r->is_temporarily_unavailable, 0, 'no tests, ok');

    # 5 tests: 5 * 2 * 16 = 160 pages used. Free = 40. Next test would add 32 -> 8 free < 40 -> defer.
    $in_flight = 5;
    is($r->is_temporarily_unavailable, 1, 'utilize-derived 40 wins over 20');
};

subtest 'status snapshot' => sub {
    local $CAP_PAGES = 200;
    my $r = _make(service_count => 2);
    my $in_flight = 1;
    $r->set_in_flight_ref(\$in_flight);
    my $st = $r->status;
    is($st->{resource},       'pipelimits',  'name');
    is($st->{cap_pages},      200,           'cap');
    is($st->{pages_per_pipe}, 16,            'pages_per_pipe');
    is($st->{service_count},  2,             'service_count');
    is($st->{service_pages},  2 * 2 * 16,    'service_pages');
    is($st->{test_pages},     1 * 2 * 16,    'test_pages');
    is($st->{free_pages},     200 - 64 - 32, 'free_pages');
    is($st->{in_flight},      1,             'in_flight from scheduler ref');
};

done_testing;
