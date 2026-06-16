use Test2::V0;
# HARNESS-DURATION-LONG

# Chunk 6 (phase D): `yath watch` is a GLOBAL runner.socket subscriber that
# renders the persistent runner's recorded output through the reusable base
# renderer (Test2::Harness2::Renderer::Base::step_runner_output), NOT a flat-log
# tailer. The persistent runner (and its preload stages) are collector-wrapped, so
# their stdout/stderr land in *-events.jsonl.zst and stream over runner.socket.
#
# This test asserts:
#   * `yath watch STOP` surfaces the runner's SIGHUP-reload line (captured in
#     runner-events.jsonl.zst, located by the base renderer over the socket);
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

yath(command => 'reload', exit => 0);

yath(
    command => 'watch',
    args    => ['STOP'],
    exit    => 0,
    test    => sub {
        my $out = shift;
        like(
            $out->{output},
            qr{yath-nested-runner \(default\) Runner caught SIGHUP, reloading},
            "watch (global socket subscriber) surfaced the runner SIGHUP-reload line from runner-events over the socket",
        );
    },
);

# No flat logs anywhere on the persistent path: only events.jsonl.zst remains.
if ($workdir) {
    ok(!-e "$workdir/output.log", "no flat output.log was created on the persistent path");
    ok(!-e "$workdir/error.log",  "no flat error.log was created on the persistent path");
    ok(-e "$workdir/runner-events.jsonl.zst", "the runner recorded its output to runner-events.jsonl.zst");
}

yath(command => 'stop', exit => 0);

done_testing;
