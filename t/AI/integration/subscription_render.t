use Test2::V0;
# HARNESS-DURATION-LONG

# Chunk 6a: the transient `yath test` command renders from the runner
# subscription (Test2::Harness2::Runner::Subscriber) plus each job's
# events.jsonl.zst fetched by path at completion, NOT from the spawned gatherer's
# event stream. This test exercises that path end to end and asserts the interim
# per-job render contract: a job's body output appears, its PASSED/FAILED status
# renders, the run-level summary renders last, and the exit code reflects
# pass/fail.

use Test2::Util qw/CAN_REALLY_FORK/;
use App::Yath2::Tester qw/yath/;

skip_all "This test requires forking" if $ENV{T2_NO_FORK} || !CAN_REALLY_FORK;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

# A passing-only run: body marker + PASSED + summary, exit 0, and the summary
# (rendered command-side from the subscription) comes AFTER the job output.
yath(
    command => 'test',
    args    => ["$dir/aaa_pass.tx", '--ext=tx', '-v'],
    exit    => 0,
    test    => sub {
        my $out  = shift;
        my $text = $out->{output};

        like($text, qr{SUBRENDER-BODY-MARKER-PASS}, "job body output appears");
        like($text, qr{PASSED.*aaa_pass\.tx},       "job PASSED status rendered");
        like($text, qr{Yath Result Summary},        "run summary rendered");
        like($text, qr{Result: PASSED},             "summary reports PASSED");

        my $body_at  = index($text, 'SUBRENDER-BODY-MARKER-PASS');
        my $final_at = index($text, 'Yath Result Summary');
        ok($body_at >= 0 && $final_at > $body_at, "final summary renders AFTER the job body (per-job ordering)");
    },
);

# A failing run: body marker + FAILED + the failed-jobs table + summary, exit
# non-zero. The pass/fail decision and the failed-jobs rollup are computed
# command-side from the subscription state + events, not a gatherer event.
yath(
    command => 'test',
    args    => ["$dir/bbb_fail.tx", '--ext=tx', '-v'],
    exit    => T(),
    test    => sub {
        my $out  = shift;
        my $text = $out->{output};

        like($text, qr{SUBRENDER-BODY-MARKER-FAIL}, "failing job body output appears");
        like($text, qr{FAILED.*bbb_fail\.tx},       "job FAILED status rendered");
        like($text, qr{The following jobs failed},  "failed-jobs rollup rendered (command-side)");
        like($text, qr{Result: FAILED},             "summary reports FAILED");
    },
);

# The log captures the same command-side stream: the penultimate record is the
# run-level harness_final the driver emits, the last is the null terminator.
yath(
    command => 'test',
    args    => ["$dir/aaa_pass.tx", '--ext=tx', '-v'],
    log     => 1,
    exit    => 0,
    test    => sub {
        my $out   = shift;
        my $final = ($out->{log}->poll())[-2];
        ok($final->{facet_data}->{harness_final}, "log carries the command-side harness_final");
        is($final->{facet_data}->{harness_final}->{pass}, T(), "harness_final reports pass");
    },
);

done_testing;
