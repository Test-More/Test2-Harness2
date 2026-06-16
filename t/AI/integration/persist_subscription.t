use Test2::V0;
# HARNESS-DURATION-LONG

# Chunk 6.1-2: the persistent `yath run` command submits over runner.socket and
# renders from the runner subscription (Renderer::Driver), exactly like the
# transient `yath test` path. This test exercises that against a live persistent
# runner and asserts:
#   * a persistent `run` renders its job body output, its PASSED/FAILED status,
#     the run-level summary (LAST), and the correct exit code -- all command-side
#     from the subscription, not the gatherer;
#   * two sequential `yath run` clients against ONE persistent runner each see
#     ONLY their own run's output (per-run transition routing end to end).

use Test2::Util qw/CAN_REALLY_FORK/;
use App::Yath2::Tester qw/yath/;

skip_all "This test is not run under automated testing"
    if $ENV{AUTOMATED_TESTING};

skip_all "This test requires forking" if $ENV{T2_NO_FORK} || !CAN_REALLY_FORK;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

yath(command => 'start', exit => 0);

# Run 1 (passing-only, filtered to .tx): body marker + PASSED + summary last,
# exit 0, rendered from the subscription.
yath(
    command => 'run',
    args    => [$dir, '--ext=tx', '-v'],
    exit    => 0,
    test    => sub {
        my $out  = shift;
        my $text = $out->{output};

        like($text, qr{PERSIST-SUBRENDER-ALPHA-MARKER}, "run-1 job body output appears (subscription render)");
        like($text, qr{PASSED.*alpha_pass\.tx},         "run-1 PASSED status rendered");
        like($text, qr{Yath Result Summary},            "run-1 summary rendered");
        like($text, qr{Result: PASSED},                 "run-1 summary reports PASSED");

        my $body_at  = index($text, 'PERSIST-SUBRENDER-ALPHA-MARKER');
        my $final_at = index($text, 'Yath Result Summary');
        ok($body_at >= 0 && $final_at > $body_at, "run-1 summary renders AFTER the job body");

        # Per-run routing: run 1 must NOT see the other run's file/marker.
        unlike($text, qr{PERSIST-SUBRENDER-BETA-MARKER}, "run-1 did NOT see run-2's body output");
        unlike($text, qr{beta_fail},                     "run-1 did NOT see run-2's file");
    },
);

# Run 2 (failing-only, filtered to .txx) against the SAME runner: body marker +
# FAILED + failed-jobs rollup, exit non-zero, and ONLY its own output.
yath(
    command => 'run',
    args    => [$dir, '--ext=txx', '-v'],
    exit    => T(),
    test    => sub {
        my $out  = shift;
        my $text = $out->{output};

        like($text, qr{PERSIST-SUBRENDER-BETA-MARKER}, "run-2 job body output appears");
        like($text, qr{FAILED.*beta_fail\.txx},        "run-2 FAILED status rendered");
        like($text, qr{The following jobs failed},     "run-2 failed-jobs rollup rendered (command-side)");
        like($text, qr{Result: FAILED},                "run-2 summary reports FAILED");

        # Per-run routing: run 2 must NOT see run 1's file/marker.
        unlike($text, qr{PERSIST-SUBRENDER-ALPHA-MARKER}, "run-2 did NOT see run-1's body output");
        unlike($text, qr{alpha_pass},                     "run-2 did NOT see run-1's file");
    },
);

yath(command => 'stop', exit => 0);

done_testing;
