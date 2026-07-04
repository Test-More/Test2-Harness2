use Test2::V0;

use App::Yath2::Tester qw/yath/;

use File::Temp qw/tempdir/;
use File::Spec;

use Test2::Util qw/CAN_REALLY_FORK/;

# bloat TODO-3 (ARCHITECTURE.md §4.2): a preload-root crash is FATAL. The preload-root
# process hosts the stages; if it dies mid-startup the runner does NOT respawn it --
# the run fails (and a persistent runner terminates) rather than papering over the
# crash with a respawn. This is deliberate: it prevents accidentally recreating
# respawn-like behavior. (HUP reload re-execs the preload-root in place, same pid,
# and is NOT a crash -- see reload.t.)
#
# CrashOncePreload makes the preload-root POSIX::_exit() exactly once during its
# load (a crash: no clean stage_host_exited), keyed off a per-run marker file. With
# the respawn apparatus removed, the run must fail (non-zero exit) -- the crash is
# not recovered. Run a few times for stability.

skip_all "Cannot fork, skipping preload-root crash test" unless CAN_REALLY_FORK;
skip_all "This test requires forking" if $ENV{T2_NO_FORK};

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

for my $i (1 .. 3) {
    my $tmp    = tempdir(CLEANUP => 1);
    my $marker = File::Spec->catfile($tmp, 'crashed-once');

    local $ENV{T2H_CRASH_ONCE_MARKER} = $marker;

    yath(
        command => 'test',
        args    => [$dir, '--ext=tx', '-A', '-PCrashOncePreload'],
        exit    => T(),    # non-zero: a preload-root crash is fatal, the run fails
        test    => sub {
            my $out = shift;

            ok(-e $marker, "run $i: the preload-root crashed once (marker was created)");
            isnt($out->{exit}, 0,
                "run $i: a preload-root crash is fatal -- the run fails rather than respawning");
        },
    );
}

done_testing;
