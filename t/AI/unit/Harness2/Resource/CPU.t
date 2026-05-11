use Test2::V0;
use Test2::Harness2::Resource::CPU;

plan skip_all => "Linux only" unless $^O eq 'linux';

# Override the sampler seam: tests push a stat-row string into a
# queue; _read_stat_first_line shifts the next one.
my @STAT_QUEUE;
no warnings 'redefine';
*Test2::Harness2::Resource::CPU::_read_stat_first_line = sub {
    @STAT_QUEUE ? shift @STAT_QUEUE : die "test forgot to enqueue a /proc/stat row";
};
use warnings;

sub _push_stat {
    my ($u, $n, $s, $idle, $iowait) = @_;
    $iowait //= 0;
    push @STAT_QUEUE, "cpu $u $n $s $idle $iowait 0 0 0 0 0\n";
}

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
    return Test2::Harness2::Resource::CPU->new(
        utilize_percent => $p{utilize_percent} // 80,
        ($p{name} ? (name => $p{name}) : ()),
    );
}

subtest 'init validation' => sub {
    ok(_make(), 'good ctor');
    like(
        dies { Test2::Harness2::Resource::CPU->new(utilize_percent => 0) },
        qr/utilize/, 'zero rejected'
    );
    like(
        dies { Test2::Harness2::Resource::CPU->new(utilize_percent => 100) },
        qr/utilize/, '100 rejected'
    );
};

subtest 'first sample returns 0%; second sample computes delta' => sub {
    my $r = _make(utilize_percent => 80);

    @STAT_QUEUE = ();
    _push_stat(1000, 0, 200, 8000);    # total = 9200, idle = 8000
    is($r->is_temporarily_unavailable, 0, 'first sample: no delta yet, treat as ok');

    _push_stat(1100, 0, 220, 8000);    # total += 120, idle += 0
                                       # delta_total = 1100-1000 + 0 + 220-200 + 8000-8000 = 100 + 20 = 120
                                       # delta_idle  = 0
                                       # busy = 100% -> >= 80% -> defer
    is($r->is_temporarily_unavailable, 1, 'all-busy delta defers at >=80%');
};

subtest 'lower load below threshold passes' => sub {
    my $r = _make(utilize_percent => 80);
    @STAT_QUEUE = ();
    _push_stat(0, 0, 0, 0);
    $r->is_temporarily_unavailable;    # prime
    _push_stat(50, 0, 50, 900);        # delta total=1000, idle=900, busy=10%
    is($r->is_temporarily_unavailable, 0, '10% busy passes');
};

subtest 'divide-by-zero falls back to previous busy_pct' => sub {
    my $r = _make(utilize_percent => 80);
    @STAT_QUEUE = ();
    _push_stat(0, 0, 0, 0);
    $r->is_temporarily_unavailable;    # prime, busy_pct=0
    _push_stat(0, 0, 0, 0);            # delta = 0 -> fallback to 0
    is($r->is_temporarily_unavailable, 0, 'fallback to previous 0% busy');
};

subtest 'pause / resume' => sub {
    my $r = _make();
    $r->mark_paused;
    is($r->is_paused, 1, 'paused');
    $r->mark_resumed;
    is($r->is_paused, 0, 'resumed');
};

subtest 'assign / release' => sub {
    my $r = _make();
    $r->assign(id => 'A', job => _job, env => {});
    like(dies { $r->release(id => 'X') }, qr/invalid/, 'unknown id');
    $r->release(id => 'A');
};

subtest 'status snapshot' => sub {
    my $r = _make(utilize_percent => 70);
    @STAT_QUEUE = ();
    _push_stat(0, 0, 0, 0);
    $r->is_temporarily_unavailable;
    _push_stat(100, 0, 100, 800);    # 20% busy
    $r->is_temporarily_unavailable;
    my $st = $r->status;
    is($st->{resource},        'cpu', 'name');
    is($st->{utilize_percent}, 70,    'threshold');
    is($st->{busy_pct},        20,    '20% busy');
    is($st->{paused},          0,     'not paused');
};

done_testing;
