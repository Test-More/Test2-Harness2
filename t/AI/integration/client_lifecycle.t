use Test2::V0;
# HARNESS-DURATION-LONG

# Ticket #41 / chunk 30: the runner lifecycle is a mode on App::Yath2::Client.
# This drives all three modes end to end through App::Yath2::Tester:
#
#   * transient -- `yath test` spawns + owns + reaps its own runner, renders the
#     run from the subscription, and returns the right pass/fail exit code.
#   * start     -- `yath start` spawns the persistent daemon and writes the
#     discovery file (the client in 'start' mode).
#   * attach    -- `yath run` discovers that persistent runner (the client in
#     'attach' mode, kill(0) liveness, no reap) and runs against it; a second run
#     against the SAME runner confirms it was never reaped between runs. `yath
#     stop` then tears it down.

use Test2::Util qw/CAN_REALLY_FORK/;
use App::Yath2::Tester qw/yath/;

skip_all "This test is not run under automated testing"
    if $ENV{AUTOMATED_TESTING};

skip_all "This test requires forking" if $ENV{T2_NO_FORK} || !CAN_REALLY_FORK;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

# --- transient mode (yath test): spawn + own + reap, pass and fail exits. ---
yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-v'],
    exit    => 0,
    test    => sub {
        my $out = shift;
        like($out->{output}, qr{CLIENT-LIFECYCLE-PASS-MARKER}, "transient: job body rendered from the subscription");
        like($out->{output}, qr{Result: PASSED},              "transient: PASSED summary");
    },
);

yath(
    command => 'test',
    args    => [$dir, '--ext=txx', '-v'],
    exit    => T(),
    test    => sub {
        my $out = shift;
        like($out->{output}, qr{CLIENT-LIFECYCLE-FAIL-MARKER}, "transient: failing job body rendered");
        like($out->{output}, qr{Result: FAILED},              "transient: FAILED summary");
    },
);

# --- start mode (yath start): spawn the daemon + write the discovery file. ---
yath(command => 'start', exit => 0);

# --- attach mode (yath run): discover the persistent runner, run against it. ---
yath(
    command => 'run',
    args    => [$dir, '--ext=tx', '-v'],
    exit    => 0,
    test    => sub {
        my $out = shift;
        like($out->{output}, qr{CLIENT-LIFECYCLE-PASS-MARKER}, "attach run-1: job body rendered");
        like($out->{output}, qr{Result: PASSED},              "attach run-1: PASSED summary");
    },
);

# A second run against the SAME persistent runner: it was never reaped by the
# first run's client (attach mode never reaps), so this still succeeds.
yath(
    command => 'run',
    args    => [$dir, '--ext=txx', '-v'],
    exit    => T(),
    test    => sub {
        my $out = shift;
        like($out->{output}, qr{CLIENT-LIFECYCLE-FAIL-MARKER}, "attach run-2: same runner still serving");
        like($out->{output}, qr{Result: FAILED},              "attach run-2: FAILED summary");
    },
);

# The persistent runner is still discoverable (the attach-mode clients never tore
# it down).
yath(
    command => 'which',
    exit    => 0,
    test    => sub {
        my $out = shift;
        like($out->{output}, qr/^\s*Found: .*yath-persist\.json$/m, "runner still discoverable after two attach runs");
    },
);

yath(command => 'stop', exit => 0);

# After stop the runner is gone (start-mode spawn + attach-mode runs + stop teardown).
yath(
    command => 'which',
    exit    => 0,
    test    => sub {
        my $out = shift;
        like($out->{output}, qr/No persistent harness was found/, "runner stopped: no discovery file");
    },
);

done_testing;
