use Test2::V0;

use App::Yath2::Tester qw/yath/;

use File::Temp qw/tempdir/;
use File::Spec;

use Test2::Util qw/CAN_REALLY_FORK/;

# Chunk 19.5 (§6.10): mid-run crash recovery for the scheduler-only runner's
# SYNCHRONOUS file_stage resolution. The companion preload_root_crash.t covers a
# crash during startup (in _load_preloads, before any stage is up). This covers a
# resolver dying MID-RUN: the runner is fully up and serving, asks a live preload
# stage to resolve a test file's stage over resolve_file_stages, and that stage
# dies while answering.
#
# file_stage is answered by a forked preload STAGE (a `preload-<name>` peer), not
# the preload-root, and an empty stage map skips the resolver entirely -- so this
# fixture has TWO stages (A, B) with a shared file_stage callback that POSIX::_exit
# (137)s exactly once, keyed off a per-run marker. _resolver_identity asks peers in
# sorted order, so 'A' answers first and crashes; the runner must NOT spin to the
# resolve deadline -- it must notice A's channel drop, fail over to the surviving
# stage 'B' (marker now present -> file_stage returns 'B'), and complete the run.
# Run a few times for stability.

skip_all "Cannot fork, skipping mid-run resolver crash test" unless CAN_REALLY_FORK;
skip_all "This test requires forking" if $ENV{T2_NO_FORK};

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

for my $i (1 .. 3) {
    my $tmp    = tempdir(CLEANUP => 1);
    my $marker = File::Spec->catfile($tmp, 'midrun-crashed-once');

    local $ENV{T2H_MIDRUN_CRASH_MARKER} = $marker;

    yath(
        command => 'test',
        args    => [$dir, '--ext=tx', '-A', '-PCrashMidRunPreload'],
        exit    => 0,
        test    => sub {
            my $out = shift;

            ok(-e $marker, "run $i: a resolver stage crashed once mid-resolve (marker created)");
            like($out->{output}, qr{PASSED.*midrun\.tx},
                "run $i: the runner failed over to a surviving stage and the run completed");
        },
    );
}

done_testing;
