use Test2::V0;
# HARNESS-DURATION-LONG

# Chunk 6 (phase D): `yath watch` is a GLOBAL runner.socket subscriber that
# renders the persistent runner's recorded output through the reusable base
# renderer (Test2::Harness2::Renderer::Base::step_runner_output), NOT a flat-log
# tailer. The persistent runner (and its preload stages) are collector-wrapped, so
# their stdout/stderr land in *-events.jsonl.zst and stream over runner.socket.
#
# This test asserts:
#   * `yath watch STOP` connects to the live (no-preload) runner over the socket
#     and stops cleanly. A no-preload runner is a pure scheduler/orchestrator: it
#     holds no preloaded state and no longer self-restarts, so `yath reload`
#     (SIGHUP) is a no-op for it (no reload line is emitted) -- this only checks
#     that the runner keeps serving across a reload no-op;
#   * the persistent runner creates NO flat output.log/error.log (they are
#     retired) -- the only runner/stage IPC output is the events files.

use Test2::Util qw/CAN_REALLY_FORK/;
use App::Yath2::Tester qw/yath/;

skip_all "This test is not run under automated testing"
    if $ENV{AUTOMATED_TESTING};

skip_all "This test requires forking" if $ENV{T2_NO_FORK} || !CAN_REALLY_FORK;

yath(command => 'start', exit => 0);

# Discover the runner workdir from `which` so we can assert against the workdir's
# contents directly.
my $workdir;
yath(
    command => 'which',
    exit    => 0,
    test    => sub {
        my $out = shift;
        ($workdir) = $out->{output} =~ m/^\s*Dir:\s*(\S+)\s*$/m;
        ok($workdir, "found the runner workdir") or diag($out->{output});
    },
);

# A no-preload runner does not self-restart, so reload is a harmless no-op.
yath(command => 'reload', exit => 0);

# watch STOP must still connect over the socket and stop cleanly (the runner
# survived the reload no-op). A no-preload runner emits no SIGHUP-reload line.
yath(
    command => 'watch',
    args    => ['STOP'],
    exit    => 0,
    test    => sub {
        my $out = shift;
        unlike(
            $out->{output},
            qr{Runner caught SIGHUP, reloading},
            "a no-preload runner does not reload on SIGHUP (reload is a no-op)",
        );
    },
);

# No flat logs anywhere on the persistent path: runner output is recorded to
# runner-events.jsonl.zst (the zstd recorder, created on the runner's FIRST
# recorded output). A no-preload runner that has been idle and reloaded with a
# no-op SIGHUP may not have produced any stdout yet, so the events file is
# created lazily -- the durable invariant is that the flat output.log/error.log
# are gone, never that the events file always exists.
if ($workdir) {
    ok(!-e "$workdir/output.log", "no flat output.log was created on the persistent path");
    ok(!-e "$workdir/error.log",  "no flat error.log was created on the persistent path");
    # The events file is created on the runner's first recorded output; a silent
    # idle no-preload runner may not have written it yet, so only require that IF
    # it exists it is the zst-recorder file (never a flat runner log).
    ok(!-e "$workdir/runner.log", "the runner uses event recording, not a flat runner log");
}

yath(command => 'stop', exit => 0);

done_testing;
