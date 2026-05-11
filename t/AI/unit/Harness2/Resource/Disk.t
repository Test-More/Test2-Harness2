use Test2::V0;
use File::Temp qw/tempdir/;
use Time::HiRes ();

use Test2::Harness2::Resource::Disk;

# Real init requires Filesys::Df; skip the whole file when absent so
# a dev box without the optional dep can still run the rest of the
# suite.
my $have_df = eval { require Filesys::Df; 1 };
skip_all "Filesys::Df not installed" unless $have_df;

subtest '_evaluate_threshold boundary semantics' => sub {
    # _evaluate_threshold is a private function in Disk.pm. Exercise the
    # boundary cases directly (free >= threshold is 'ok', strictly less
    # is 'low'); the integration subtests below cover the path through
    # available()/_take_sample.
    my $eval = \&Test2::Harness2::Resource::Disk::_evaluate_threshold;

    is($eval->({kind => 'pct', value => 25}, 250, 1000), 'ok',  'pct: exactly at threshold');
    is($eval->({kind => 'pct', value => 25}, 251, 1000), 'ok',  'pct: just above threshold');
    is($eval->({kind => 'pct', value => 25}, 249, 1000), 'low', 'pct: just below threshold');
    is($eval->({kind => 'pct', value => 25}, 0,   1000), 'low', 'pct: zero free');

    my $cap = 512 * 1024;
    is($eval->({kind => 'bytes', value => $cap}, $cap,     'ignored'), 'ok',  'bytes: at threshold');
    is($eval->({kind => 'bytes', value => $cap}, $cap + 1, 'ignored'), 'ok',  'bytes: above threshold');
    is($eval->({kind => 'bytes', value => $cap}, $cap - 1, 'ignored'), 'low', 'bytes: below threshold');
    is($eval->({kind => 'bytes', value => $cap}, 0,        'ignored'), 'low', 'bytes: zero free');
};

subtest 'init requires non-empty mounts' => sub {
    like(
        dies { Test2::Harness2::Resource::Disk->new() },
        qr/'mounts' is required/, 'no mounts'
    );
    like(
        dies { Test2::Harness2::Resource::Disk->new(mounts => {}) },
        qr/'mounts' is required/, 'empty mounts'
    );
};

subtest 'init croaks on missing mount path' => sub {
    like(
        dies {
            Test2::Harness2::Resource::Disk->new(
                mounts => {
                    '/no/such/path/should/exist' => {
                        min_free => {kind => 'pct', value => 25},
                    },
                },
            );
        },
        qr{/no/such/path/should/exist},
        'missing path named'
    );
};

subtest 'init succeeds for a real mount' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $r   = Test2::Harness2::Resource::Disk->new(
        mounts => {$tmp => {min_free => {kind => 'pct', value => 25}}},
    );
    is($r->resource_name, 'disk', 'name');
};

sub _make_resource {
    my (%p)       = @_;
    my $tmp       = tempdir(CLEANUP => 1);
    my $threshold = $p{threshold} // {kind => 'pct', value => 25};
    return Test2::Harness2::Resource::Disk->new(
        mounts => {$tmp => {min_free => $threshold}},
    );
}

# Stand-in "job" object -- available() only requires the param to be
# defined, it does not introspect.
sub _fake_job { bless {}, 'TFakeJob' }

subtest 'available() returns 1 when free space meets pct threshold' => sub {
    my $r = _make_resource();
    no warnings 'redefine';
    local *Filesys::Df::df = sub {
        return {bavail => 10_000, blocks => 10_000};    # 100% free
    };
    is($r->available(job => _fake_job()), 1, 'plenty of space');
};

subtest 'available() returns 0 when below pct threshold' => sub {
    my $r = _make_resource(threshold => {kind => 'pct', value => 50});
    no warnings 'redefine';
    local *Filesys::Df::df = sub {
        return {bavail => 100, blocks => 1000};         # 10% free, want 50%
    };
    is($r->available(job => _fake_job()), 0, 'low space defers');
};

subtest 'available() honours bytes threshold' => sub {
    my $r = _make_resource(threshold => {kind => 'bytes', value => 5 * 1024**2});
    no warnings 'redefine';
    local *Filesys::Df::df = sub {
        return {bavail => 1, blocks => 10_000};         # 1024 bytes free, want 5MB
    };
    is($r->available(job => _fake_job()), 0, 'low bytes defers');
};

subtest 'three consecutive sample failures flip permanent_broken' => sub {
    my $r = _make_resource();

    no warnings 'redefine';
    local *Filesys::Df::df = sub { die "statvfs: device gone\n" };

    is($r->is_permanent_broken, 0, 'starts ok');
    $r->available(job => _fake_job());
    is($r->is_permanent_broken, 0, 'one failure');
    $r->available(job => _fake_job());
    is($r->is_permanent_broken, 0, 'two failures');
    $r->available(job => _fake_job());
    is($r->is_permanent_broken, 1, 'three -> permanent_broken');
};

subtest 'state-transition methods' => sub {
    my $r = _make_resource();

    is($r->is_broken,           0, 'starts not broken');
    is($r->is_permanent_broken, 0, 'starts not permanent');
    is($r->is_paused,           0, 'starts not paused');

    $r->mark_broken;
    is($r->is_broken, 1, 'mark_broken');

    $r->mark_resumed;
    is($r->is_broken, 0, 'mark_resumed clears transient broken');

    $r->mark_paused;
    is($r->is_paused, 1, 'mark_paused');
    $r->mark_resumed;
    is($r->is_paused, 0, 'mark_resumed clears paused');

    $r->mark_permanent_broken;
    is($r->is_permanent_broken, 1, 'mark_permanent_broken sets permanent');
    is($r->is_broken,           1, 'mark_permanent_broken also sets broken');

    $r->mark_resumed;
    is($r->is_permanent_broken, 1, 'mark_resumed leaves permanent intact');
    is($r->is_broken,           1, 'mark_resumed leaves broken (because permanent)');
};

subtest 'available() refreshes all mounts even when one is low' => sub {
    # Two-mount resource: one always low, one always ok. Without the
    # 'refresh all before check' fix the second mount's sample would
    # never get refreshed because the first mount short-circuits.
    my $tmp_a = tempdir(CLEANUP => 1);
    my $tmp_b = tempdir(CLEANUP => 1);

    my $r = Test2::Harness2::Resource::Disk->new(
        mounts => {
            $tmp_a => {min_free => {kind => 'pct', value => 50}},
            $tmp_b => {min_free => {kind => 'pct', value => 50}},
        },
    );

    no warnings 'redefine';
    local *Filesys::Df::df = sub {
        my $path = shift;
        return {bavail => 100, blocks => 1000} if $path eq $tmp_a;    # 10% low
        return {bavail => 800, blocks => 1000};                       # 80% ok
    };

    my $before = Time::HiRes::time();
    is($r->available(job => _fake_job()), 0, 'overall result is defer');
    ok($r->{samples}{$tmp_a}{ts} >= $before, 'mount A sample fresh');
    ok($r->{samples}{$tmp_b}{ts} >= $before, 'mount B sample fresh');
};

package TFakeTestFile {
    sub new      { my ($c, $rel) = @_; bless {rel => $rel}, $c }
    sub relative { $_[0]->{rel} }
}

package TFakeJobWithFile {
    sub new       { my ($c, $tf) = @_; bless {tf => $tf}, $c }
    sub test_file { $_[0]->{tf} }
}

subtest 'assign records id, release drops it' => sub {
    my $r  = _make_resource();
    my $tf = TFakeTestFile->new('t/foo.t');
    my $j  = TFakeJobWithFile->new($tf);

    no warnings 'redefine';
    local *Filesys::Df::df = sub { {bavail => 10_000, blocks => 10_000} };

    $r->assign(id => 'A1', job => $j, env => {});
    $r->assign(id => 'A2', job => $j, env => {});
    is([sort keys %{$r->assignments}], ['A1', 'A2'], 'two ids tracked');

    $r->release(id => 'A1');
    is([keys %{$r->assignments}], ['A2'], 'A1 dropped');

    like(
        dies { $r->assign(id => 'A2', job => $j, env => {}) },
        qr/duplicate/, 'duplicate id croaks'
    );
    like(
        dies { $r->release(id => 'unknown') },
        qr/invalid release/, 'unknown id croaks'
    );
};

subtest 'status snapshot shape' => sub {
    my $r   = _make_resource();
    my $tmp = (keys %{$r->mounts})[0];

    no warnings 'redefine';
    local *Filesys::Df::df = sub { {bavail => 10_000, blocks => 10_000} };

    my $now = 2000;
    local $Test2::Harness2::Util::HiResTime::CLOCK = sub { $now };

    $r->available(job => _fake_job);

    my $tf = TFakeTestFile->new('t/foo.t');
    my $j  = TFakeJobWithFile->new($tf);
    $r->assign(id => 'X1', job => $j, env => {});

    my $st = $r->status;
    is($st->{resource},  'disk', 'resource name');
    is($st->{broken},    0,      'not broken');
    is($st->{permanent}, 0,      'not permanent');
    is($st->{paused},    0,      'not paused');

    is($st->{mounts}->{$tmp}->{state}, 'ok', 'state ok');
    ok(exists $st->{mounts}->{$tmp}->{free_bytes},  'free_bytes present');
    ok(exists $st->{mounts}->{$tmp}->{total_bytes}, 'total_bytes present');
    ok(exists $st->{mounts}->{$tmp}->{used_pct},    'used_pct present');
    is(
        $st->{mounts}->{$tmp}->{threshold},
        {kind => 'pct', value => 25},
        'threshold echoed'
    );
    is($st->{mounts}->{$tmp}->{sample_age},           0, 'fresh sample');
    is($st->{mounts}->{$tmp}->{consecutive_failures}, 0, 'no failures');

    is(scalar @{$st->{assignments}},    1,         'one assignment');
    is($st->{assignments}->[0]->{id},   'X1',      'id');
    is($st->{assignments}->[0]->{test}, 't/foo.t', 'test path');
    ok(exists $st->{assignments}->[0]->{assigned_at}, 'assigned_at');
    is($st->{assignments}->[0]->{age}, 0, 'age');
};

subtest 'status does not trigger statvfs' => sub {
    my $r     = _make_resource();
    my $calls = 0;
    no warnings 'redefine';
    local *Filesys::Df::df = sub { $calls++; {bavail => 10_000, blocks => 10_000} };

    $r->available(job => _fake_job);
    is($calls, 1, 'available() sampled once');

    $r->status for 1 .. 5;
    is($calls, 1, 'status did not re-sample');
};

subtest 'parse_options output is consumable by new()' => sub {
    my $tmp  = tempdir(CLEANUP => 1);
    my %args = Test2::Harness2::Resource::Disk->parse_options(
        # noise from $res_s->all in start.pm
        slots       => 4,
        job_slots   => 1,
        classes     => {},
        utilize     => 80,
        no_resource => 0,
        # the real positional entry
        "$tmp:25%",
    );
    my $r = Test2::Harness2::Resource::Disk->new(%args);
    is($r->resource_name,    'disk', 'constructed');
    is([keys %{$r->mounts}], [$tmp], 'one mount');
};

done_testing;
