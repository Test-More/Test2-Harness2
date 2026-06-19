use Test2::V0;

use App::Yath2::Tester qw/yath/;

use File::Temp qw/tempdir/;
use File::Spec;

use Test2::Util qw/CAN_REALLY_FORK/;

# Chunk 19.5 (§6.10): preload-root crash resilience. The preload-root process hosts
# the stages; if it dies mid-startup the runner must respawn a fresh incarnation and
# recover the run rather than hang or fail.
#
# CrashOncePreload makes the preload-root POSIX::_exit() exactly once during its load
# (a crash: no clean stage_host_exited), keyed off a per-run marker file. The runner
# should detect the dead preload-root, respawn it, and the second incarnation (marker
# present) loads normally so the run completes and the test passes. Run a few times
# for stability.

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
        exit    => 0,
        test    => sub {
            my $out = shift;

            ok(-e $marker, "run $i: the preload-root crashed once (marker was created)");
            like($out->{output}, qr{PASSED.*crash\.tx},
                "run $i: the run recovered from the preload-root crash and the test passed");
        },
    );
}

done_testing;
