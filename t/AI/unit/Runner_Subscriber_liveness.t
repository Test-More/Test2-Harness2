use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;
use Time::HiRes qw/time/;

use Test2::Harness2::Runner::Subscriber;

# #134 finding 108: a runner that dies after binding (or before binding) its
# socket must not cost a subscriber a flat CONNECT_TIMEOUT (30s) stall in
# _connect. A liveness_check coderef that reports the runner gone makes subscribe
# fail fast.

subtest fast_fail_when_runner_gone => sub {
    my $dir = tempdir(CLEANUP => 1);    # contains no runner.socket

    my $sub = Test2::Harness2::Runner::Subscriber->new(
        workdir        => $dir,
        liveness_check => sub { 0 },    # runner is gone
    );

    my $start = time;
    my $ok    = eval { $sub->subscribe; 1 };
    my $err   = $@;
    my $took  = time - $start;

    ok(!$ok, "subscribe failed (runner gone)");
    like($err, qr/Runner is gone/, "failed via the liveness check, not a socket timeout");
    ok($took < 2, "failed fast in ${took}s (well under the 30s CONNECT_TIMEOUT)");
};

subtest no_liveness_check_assumes_alive => sub {
    my $dir = tempdir(CLEANUP => 1);

    # Absent liveness_check: _runner_alive returns true, so the connect loop keeps
    # retrying. We do not want a 30s test, so only prove the helper's default here.
    my $sub = Test2::Harness2::Runner::Subscriber->new(workdir => $dir);
    ok($sub->_runner_alive, "with no liveness_check, the runner is assumed alive");
};

done_testing;
