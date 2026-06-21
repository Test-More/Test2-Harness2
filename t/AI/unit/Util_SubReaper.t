use Test2::V0;
use POSIX ();

use Test2::Harness2::Util::SubReaper qw/
    acquire_subreaper
    release_subreaper
    subreaper_supported
    subreaper_mechanism
/;

# Invariant: support flag and mechanism string agree.
is(
    !!subreaper_supported(),
    defined(subreaper_mechanism()) ? 1 : '',
    "subreaper_supported() agrees with defined(subreaper_mechanism())",
);

skip_all "no subreaper support on this platform" unless subreaper_supported();

like(subreaper_mechanism(), qr/^(prctl|procctl)$/, "known mechanism");

# End-to-end check that the subreaper flag actually causes an orphaned
# grandchild to reparent to us, not to init.
#
# Run the whole experiment in a forked subject so we don't leave this test
# process permanently marked as a subreaper. Ported from the local
# Test2-Harness2-ChildSubReaper t/40-subreaper-behavior.t.

my $subject_pid = fork // die "fork: $!";
if (!$subject_pid) {
    acquire_subreaper() or POSIX::_exit(10);

    my $child = fork // POSIX::_exit(11);
    if (!$child) {
        # Child forks a grandchild and exits immediately; the grandchild becomes
        # orphaned. With the subreaper flag the grandchild reparents to the
        # subject (us), not to PID 1.
        my $grandchild = fork // POSIX::_exit(12);
        if (!$grandchild) {
            # Grandchild: give the middle child time to exit so we get orphaned,
            # then exit with a recognizable status.
            sleep 1;
            POSIX::_exit(42);
        }

        # Middle child exits right away to orphan the grandchild.
        POSIX::_exit(0);
    }

    # Reap both descendants. Without subreaper support the grandchild would have
    # reparented to init(1) and we would never see it.
    my %saw;
    while ((my $reaped = waitpid(-1, 0)) > 0) {
        $saw{$reaped} = $?;
    }

    my @statuses       = values %saw;
    my $got_grandchild = grep { ($_ >> 8) == 42 } @statuses;
    POSIX::_exit(50) unless keys(%saw) >= 2;
    POSIX::_exit(51) unless $got_grandchild == 1;

    POSIX::_exit(0);
}

waitpid($subject_pid, 0);
my $code = $? >> 8;
is($code, 0, "subject reaped its orphaned grandchild (exit $code)");

ok(release_subreaper(), "release_subreaper() succeeds on a supported platform");

done_testing;
