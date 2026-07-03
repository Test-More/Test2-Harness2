use Test2::V0;
use v5.38;

use Test2::Harness2::Runner::Resource::UnixLimits;
use Test2::Harness2::Runner::Resource::Disk;

# The OS-limit throttle resources (#59) read their metrics IN-RESOURCE,
# runner-local (NOT via the shared system-load sampler): UnixLimits reads
# /proc/self/{limits,status,fd}; Disk samples each mount via Filesys::Df. A defer
# is a transient wait (available => 0); a permanently broken mount is a skip
# (available => -1). On an unsupported platform both deactivate (no throttle).

# ---------------------------------------------------------------------------
# UnixLimits
# ---------------------------------------------------------------------------

# A UnixLimits subclass whose /proc readers and supported flag are overridable,
# so we can drive the ok/low logic deterministically without a real /proc.
package FakeUnixLimits {
    use parent -norequire, 'Test2::Harness2::Runner::Resource::UnixLimits';

    sub _read_self_limits { return $_[0]->{fake_limits} // {} }
    sub _read_self_status { return $_[0]->{fake_status} // {} }
    sub _count_self_fd    { return $_[0]->{fake_fd}     // 0 }
}

subtest unixlimits_inline_parse => sub {
    my $r = Test2::Harness2::Runner::Resource::UnixLimits->new(arg => 'nofile=10%');
    is($r->name, 'unixlimits', "default name");
    is($r->nofile, {kind => 'pct', value => 10}, "nofile=10% parsed as pct");
    is($r->as, undef, "as off by default");
};

# #138: the nproc dimension was DROPPED (RLIMIT_NPROC is per-real-UID and cannot
# be measured cheaply/correctly from the runner). An explicit nproc= must be a
# hard error, NEVER silently ignored -- that would be the gate-that-cannot-fire
# defect in a new costume.
subtest unixlimits_nproc_is_disabled => sub {
    my $ok = eval { Test2::Harness2::Runner::Resource::UnixLimits->new(arg => 'nproc=128'); 1 };
    my $err = $@;
    ok(!$ok, "explicit nproc= croaks (never silently ignored)");
    like($err, qr/nproc dimension is disabled/, "croak explains the dimension is disabled");
    like($err, qr/per real UID/, "croak explains the per-real-UID accounting reason");

    # Also a hard error when combined with a valid dimension in one arg string.
    my $ok2 = eval { Test2::Harness2::Runner::Resource::UnixLimits->new(arg => 'nofile=10%,nproc=128'); 1 };
    ok(!$ok2, "nproc= in a multi-dimension arg still croaks");

    # The accessor is gone entirely.
    ok(!Test2::Harness2::Runner::Resource::UnixLimits->can('nproc'), "no nproc accessor remains");
};

subtest unixlimits_defaults => sub {
    my $r = Test2::Harness2::Runner::Resource::UnixLimits->new();
    is($r->nofile, {kind => 'pct', value => 10}, "nofile defaults to 10%");
};

subtest unixlimits_bare_pct => sub {
    my $r = Test2::Harness2::Runner::Resource::UnixLimits->new(arg => '20%');
    is($r->nofile, {kind => 'pct', value => 20}, "bare pct -> nofile");
};

subtest unixlimits_as_inline => sub {
    my $r = Test2::Harness2::Runner::Resource::UnixLimits->new(arg => 'as=512mb');
    is($r->as, {kind => 'bytes', value => 512 * 1024 * 1024}, "as=512mb parsed as bytes");
};

subtest unixlimits_bad_inline_croaks => sub {
    my $ok = eval { Test2::Harness2::Runner::Resource::UnixLimits->new(arg => 'bogus=1'); 1 };
    ok(!$ok, "unrecognised inline entry croaks");
};

subtest unixlimits_defer_logic => sub {
    # nofile soft cap 100, threshold 10% => need 10 free. fd count 95 => 5 free => low.
    my $r = FakeUnixLimits->new(arg => 'nofile=10%', min_concurrent => 1);
    $r->{+Test2::Harness2::Runner::Resource::UnixLimits::SUPPORTED()} = 1;
    $r->{fake_limits} = {nofile => 100};
    $r->{fake_fd}     = 95;

    # 0 in flight: under the floor, never defers even when saturated.
    is($r->available({job_id => 'j1'}), 1, "under min_concurrent floor -> available");

    $r->record('j1', {});
    is($r->in_flight, 1, "tracks one in-flight job");
    is($r->available({job_id => 'j2'}), 0, "nofile 5 free < 10 needed and floor met -> DEFER");

    # Free up fds: 50 used => 50 free >= 10 => ok.
    $r->{fake_fd} = 50;
    is($r->available({job_id => 'j2'}), 1, "nofile now has headroom -> available");

    $r->release('j1');
    is($r->in_flight, 0, "release frees the in-flight slot");
};

subtest unixlimits_unlimited_cap_never_defers => sub {
    my $r = FakeUnixLimits->new(arg => 'nofile=10%', min_concurrent => 1);
    $r->{+Test2::Harness2::Runner::Resource::UnixLimits::SUPPORTED()} = 1;
    $r->{fake_limits} = {nofile => undef};    # unlimited
    $r->{fake_fd}     = 9999;
    $r->record('j1', {});
    is($r->available({job_id => 'j2'}), 1, "unlimited soft caps -> never defers");
};

subtest unixlimits_unsupported_is_infinite => sub {
    my $r = FakeUnixLimits->new(arg => 'nofile=10%', min_concurrent => 1);
    # Force unsupported.
    $r->{+Test2::Harness2::Runner::Resource::UnixLimits::SUPPORTED()} = 0;
    $r->record('j1', {});
    is($r->is_temporarily_unavailable, 0, "unsupported -> never temporarily unavailable");
    is($r->available({job_id => 'j2'}), 1, "unsupported -> always available (no throttle)");
};

# #138 verify line: cover REAL semantics, not just mocks. On Linux the real
# resource must be supported and read a live nofile dimension from /proc, with no
# nproc dimension present.
subtest unixlimits_real_proc_smoke => sub {
    skip_all "not linux with /proc" unless $^O eq 'linux' && -d '/proc/self/fd';

    my $r = Test2::Harness2::Runner::Resource::UnixLimits->new;
    ok($r->is_supported, "real resource is supported on this Linux host");

    my $dims = $r->_dimension_states;
    ok(exists $dims->{nofile}, "nofile dimension present from real /proc");
    ok(!exists $dims->{nproc}, "no nproc dimension");

    my $nofile = $dims->{nofile};
    ok($nofile->{soft_cap} > 0, "real nofile soft_cap is a positive number ($nofile->{soft_cap})");
    ok($nofile->{current} > 0,  "real open-fd current is a positive number ($nofile->{current})");
};

# ---------------------------------------------------------------------------
# Disk
# ---------------------------------------------------------------------------

# Stub Filesys::Df so the Disk tests do not depend on a real mount sampling a
# particular value (and run even where Filesys::Df behaves oddly). We install our
# own df() that reads from a package global.
BEGIN {
    package Filesys::Df;
    our $RESULT;
    no warnings 'redefine';
    *Filesys::Df::df = sub { return $RESULT };
    $INC{'Filesys/Df.pm'} //= __FILE__;    # satisfy the lazy require in init()
}

subtest disk_inline_parse => sub {
    local $Filesys::Df::RESULT = {bavail => 1000, blocks => 2000};
    my $r = Test2::Harness2::Runner::Resource::Disk->new(arg => '/tmp:25%');
    is($r->name, 'disk', "default name");
    is($r->mounts->{'/tmp'}{min_free}, {kind => 'pct', value => 25}, "threshold parsed (default unit %)");
};

subtest disk_no_mount_croaks => sub {
    my $ok = eval { Test2::Harness2::Runner::Resource::Disk->new(); 1 };
    ok(!$ok, "Disk with no mount croaks");
};

subtest disk_pct_gate => sub {
    # / exists everywhere. 50% free now.
    local $Filesys::Df::RESULT = {bavail => 1000, blocks => 2000};
    my $r = Test2::Harness2::Runner::Resource::Disk->new(arg => '/tmp:25%');

    is($r->available({job_id => 'j1'}), 1, "50% free >= 25% threshold -> available");

    # Drop to 10% free.
    $Filesys::Df::RESULT = {bavail => 100, blocks => 1000};
    is($r->available({job_id => 'j1'}), 0, "10% free < 25% threshold -> DEFER (0, a wait)");

    my $s = $r->samples->{'/tmp'};
    is($s->{state}, 'low', "mount recorded low");
    is($s->{free_bytes}, 100, "fresh free bytes recorded");
};

subtest disk_bytes_gate => sub {
    local $Filesys::Df::RESULT = {bavail => 2_000_000, blocks => 10_000_000};
    my $r = Test2::Harness2::Runner::Resource::Disk->new(arg => '/tmp:1mb');
    is($r->available({job_id => 'j1'}), 1, "2MB free >= 1MB threshold -> available");

    $Filesys::Df::RESULT = {bavail => 500_000, blocks => 10_000_000};
    is($r->available({job_id => 'j1'}), 0, "500KB free < 1MB threshold -> DEFER");
};

subtest disk_permanent_broken_after_3_failures => sub {
    local $Filesys::Df::RESULT = undef;    # df returns nothing -> sample failure
    my $r = Test2::Harness2::Runner::Resource::Disk->new(arg => '/tmp:25%');

    is($r->available({job_id => 'j1'}), 0, "1st sample failure -> defer");
    is($r->available({job_id => 'j1'}), 0, "2nd sample failure -> defer");
    is($r->available({job_id => 'j1'}), -1, "3rd consecutive failure -> permanent skip (-1)");
};

done_testing;
