use Test2::V0;
use File::Temp qw/tempdir/;

use Test2::Harness2::Resource::Disk;

# Real init requires Filesys::Df; skip the whole file when absent so
# a dev box without the optional dep can still run the rest of the
# suite.
my $have_df = eval { require Filesys::Df; 1 };
skip_all "Filesys::Df not installed" unless $have_df;

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

subtest 'init rejects bad poll_interval' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    like(
        dies {
            Test2::Harness2::Resource::Disk->new(
                mounts        => {$tmp => {min_free => {kind => 'pct', value => 25}}},
                poll_interval => 0,
            );
        },
        qr/poll_interval/,
        'zero rejected'
    );
    like(
        dies {
            Test2::Harness2::Resource::Disk->new(
                mounts        => {$tmp => {min_free => {kind => 'pct', value => 25}}},
                poll_interval => 'abc',
            );
        },
        qr/poll_interval/,
        'non-numeric rejected'
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
    is($r->poll_interval, 5,      'default poll_interval');
};

sub _make_resource {
    my (%p)       = @_;
    my $tmp       = tempdir(CLEANUP => 1);
    my $threshold = $p{threshold} // {kind => 'pct', value => 25};
    return Test2::Harness2::Resource::Disk->new(
        mounts        => {$tmp => {min_free => $threshold}},
        poll_interval => $p{poll_interval} // 5,
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

subtest 'available() caches within poll_interval and refreshes after' => sub {
    my $r = _make_resource(poll_interval => 5);

    my $calls = 0;
    no warnings 'redefine';
    local *Filesys::Df::df = sub { $calls++; return {bavail => 10_000, blocks => 10_000} };

    # Pin the clock.
    my $now = 1000;
    local $Test2::Harness2::Resource::Disk::CLOCK = sub { $now };

    is($r->available(job => _fake_job()), 1, 'first call');
    is($calls,                            1, 'sampled once');

    # Within TTL: cache hit.
    $r->available(job => _fake_job());
    $r->available(job => _fake_job());
    is($calls, 1, 'still one statvfs');

    # Past TTL: re-sample.
    $now += 6;
    $r->available(job => _fake_job());
    is($calls, 2, 're-sampled after TTL');
};

subtest 'three consecutive sample failures flip permanent_broken' => sub {
    my $r   = _make_resource();
    my $now = 1000;
    local $Test2::Harness2::Resource::Disk::CLOCK = sub { $now };

    no warnings 'redefine';
    local *Filesys::Df::df = sub { die "statvfs: device gone\n" };

    is($r->is_permanent_broken, 0, 'starts ok');
    $r->available(job => _fake_job());
    $now += 6;
    is($r->is_permanent_broken, 0, 'one failure');
    $r->available(job => _fake_job());
    $now += 6;
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
        poll_interval => 5,
    );

    no warnings 'redefine';
    local *Filesys::Df::df = sub {
        my $path = shift;
        return {bavail => 100, blocks => 1000} if $path eq $tmp_a;    # 10% low
        return {bavail => 800, blocks => 1000};                       # 80% ok
    };

    my $now = 5000;
    local $Test2::Harness2::Resource::Disk::CLOCK = sub { $now };

    is($r->available(job => _fake_job()), 0, 'overall result is defer');

    # Both samples must be fresh (ts == $now).
    is($r->{samples}{$tmp_a}{ts}, $now, 'mount A sample fresh');
    is($r->{samples}{$tmp_b}{ts}, $now, 'mount B sample fresh');
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

done_testing;
