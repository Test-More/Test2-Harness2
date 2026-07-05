use Test2::V0;
use POSIX ();

# Force the pure-Perl fallback BEFORE loading the module, so this exercises the
# inline syscall backend even on a system where the optional XS module
# (Test2::Harness2::ChildSubReaper) IS installed. This guarantees the pure-Perl
# implementation keeps working regardless of whether the XS module is present.
BEGIN { $ENV{T2_HARNESS_SUBREAPER_NO_XS} = 1 }

use Test2::Harness2::Util::SubReaper qw/
    acquire_subreaper
    release_subreaper
    subreaper_supported
    subreaper_mechanism
    subreaper_backend
/;

# subreaper_backend() triggers the (lazy) backend resolve.
is(subreaper_backend(), 'perl',
    "T2_HARNESS_SUBREAPER_NO_XS forces the pure-Perl backend");

ok(!$INC{'Test2/Harness2/ChildSubReaper.pm'},
    "the optional XS module was NOT loaded on the forced pure-Perl path");

# Invariant: support flag and mechanism string agree.
is(
    !!subreaper_supported(),
    defined(subreaper_mechanism()) ? 1 : '',
    "subreaper_supported() agrees with defined(subreaper_mechanism()) (pure-Perl)",
);

skip_all "no pure-Perl subreaper support on this platform"
    unless subreaper_supported();

like(subreaper_mechanism(), qr/^(prctl|procctl)$/, "known pure-Perl mechanism");

# End-to-end: the inline syscall really makes an orphaned grandchild reparent to
# us, not to init(1). Run the whole experiment in a forked subject so we don't
# leave this test process permanently marked as a subreaper.
my $subject_pid = fork // die "fork: $!";
if (!$subject_pid) {
    acquire_subreaper() or POSIX::_exit(10);

    my $child = fork // POSIX::_exit(11);
    if (!$child) {
        my $grandchild = fork // POSIX::_exit(12);
        if (!$grandchild) {
            # Grandchild: outlive the middle child so we become orphaned, then
            # exit with a recognizable status.
            sleep 1;
            POSIX::_exit(42);
        }
        # Middle child exits right away to orphan the grandchild.
        POSIX::_exit(0);
    }

    # With the subreaper flag set (pure-Perl path), the orphaned grandchild
    # reparents to us and we can reap it; without it, it would go to init(1).
    my %saw;
    while ((my $reaped = waitpid(-1, 0)) > 0) {
        $saw{$reaped} = $?;
    }

    my $got_grandchild = grep { ($_ >> 8) == 42 } values %saw;
    POSIX::_exit(50) unless keys(%saw) >= 2;
    POSIX::_exit(51) unless $got_grandchild == 1;

    POSIX::_exit(0);
}

waitpid($subject_pid, 0);
my $code = $? >> 8;
is($code, 0, "pure-Perl subreaper reaped its orphaned grandchild (exit $code)");

ok(release_subreaper(), "release_subreaper() succeeds on the pure-Perl backend");

done_testing;
