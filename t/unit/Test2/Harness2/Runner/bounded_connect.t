use Test2::V0;
# HARNESS-DURATION-SHORT
# HARNESS-NO-PRELOAD
use v5.38;

use File::Temp qw/tempdir/;
use File::Spec;
use Time::HiRes qw/time/;

use Socket qw/PF_UNIX SOCK_STREAM sockaddr_un/;
use Fcntl qw/F_GETFL F_SETFL O_NONBLOCK/;

use Test2::Harness2::Util qw/connect_unix_nb/;
use Test2::Harness2::Runner::Client;
use Test2::Harness2::Runner::Subscriber;

# Regression coverage for ticket #157: the bounded, NON-BLOCKING unix connect that
# discovery probing and BOTH runner dialers (Runner::Client / Runner::Subscriber)
# now share. A plain BLOCKING connect() to a bound-but-wedged runner (one whose
# accept backlog is full) blocks forever in the kernel's unix_wait_for_peer, so the
# dialers' CONNECT_TIMEOUT deadline could never fire and the client hung. The shared
# connect_unix_nb primitive makes every such dial return promptly instead -- so the
# dialer honors its deadline (Client croaks; Subscriber croaks) rather than hanging.

# Fast-timeout subclass so we do not sit through Subscriber's flat 30s CONNECT_TIMEOUT
# (Client's is env-overridable via YATH_RUNNER_CONNECT_TIMEOUT; Subscriber's is not).
{
    package My::FastSub;
    use parent -norequire, 'Test2::Harness2::Runner::Subscriber';
    sub CONNECT_TIMEOUT { 1 }
}

# Bind a listener with a tiny backlog and never accept() it, then FILL the accept
# queue with non-blocking pending connects (blocking ones would hang this test --
# the very bug). A subsequent connect then cannot be queued: a blocking connect
# would wedge in the kernel, a non-blocking one returns at once. Returns ($workdir,
# $sock_path, $listen, \@pending) -- the caller holds the listener + pending fds so
# the backlog stays full for the duration of the check.
sub wedged_listener {
    my $workdir   = tempdir(CLEANUP => 1);
    my $sock_path = File::Spec->catfile($workdir, 'runner.socket');

    CORE::socket(my $listen, PF_UNIX, SOCK_STREAM, 0) or die "socket: $!";
    bind($listen, sockaddr_un($sock_path)) or die "bind: $!";
    listen($listen, 1) or die "listen: $!";

    my @pending;
    for (1 .. 50) {
        CORE::socket(my $c, PF_UNIX, SOCK_STREAM, 0) or last;
        my $fl = fcntl($c, F_GETFL, 0);
        fcntl($c, F_SETFL, ($fl // 0) | O_NONBLOCK);
        connect($c, sockaddr_un($sock_path));    # EAGAIN/EINPROGRESS; never blocks
        push @pending, $c;
    }

    return ($workdir, $sock_path, $listen, \@pending);
}

subtest connect_unix_nb_primitive => sub {
    my ($workdir, $sock_path, $listen, $pending) = wedged_listener();

    my $start = time;
    my ($sock, $errno) = connect_unix_nb($sock_path, 0.5);
    my $elapsed = time - $start;

    # The whole point of #157: the dial NEVER hangs, it returns within its bound.
    ok($elapsed < 2, "connect_unix_nb returned within its bounded window (${elapsed}s), no hang");
    ok(!$sock, "a wedged/full-backlog listener yields no connected socket");
    ok($errno, "  ... and reports a failing errno ($errno), not success");

    # A listener with room accepts immediately (AF_UNIX connect completes without a
    # matching accept() when the backlog has space) -- the success path returns the
    # connected socket.
    my $live_dir = tempdir(CLEANUP => 1);
    my $live_path = File::Spec->catfile($live_dir, 'runner.socket');
    CORE::socket(my $live_listen, PF_UNIX, SOCK_STREAM, 0) or die "socket: $!";
    bind($live_listen, sockaddr_un($live_path)) or die "bind: $!";
    listen($live_listen, 5) or die "listen: $!";

    my ($lsock, $lerr) = connect_unix_nb($live_path, 0.5);
    ok($lsock, "connect_unix_nb returns a connected socket for a listener with backlog room");
    is($lerr, 0, "  ... with a zero errno");
    close($lsock) if $lsock;

    # A missing socket path fails fast (no hang) rather than blocking.
    my $gone_path = File::Spec->catfile(tempdir(CLEANUP => 1), 'runner.socket');
    my $g_start = time;
    my ($gsock, $gerr) = connect_unix_nb($gone_path, 0.5);
    ok(!$gsock, "connect_unix_nb fails for a missing socket");
    ok((time - $g_start) < 2, "  ... and fails fast, no hang");
};

subtest client_croaks_not_hangs => sub {
    my ($workdir, $sock_path, $listen, $pending) = wedged_listener();

    # Shrink the outer connect deadline so the croak is quick; production default is
    # 30s. This env is the same #121 knob the stop/kill regression uses.
    local $ENV{YATH_RUNNER_CONNECT_TIMEOUT} = 1;

    my $client = Test2::Harness2::Runner::Client->new(workdir => $workdir);

    my $start = time;
    my $err   = dies { $client->connection };
    my $elapsed = time - $start;

    like(
        $err,
        qr/Timed out waiting for runner socket .* to accept connections/,
        "Runner::Client croaks its connect-timeout instead of hanging on a wedged listener",
    );
    ok($elapsed < 15, "  ... and returns near its ~1s deadline (${elapsed}s), not a 30s+ hang");
};

subtest subscriber_croaks_not_hangs => sub {
    my ($workdir, $sock_path, $listen, $pending) = wedged_listener();

    my $sub = My::FastSub->new(workdir => $workdir);

    my $start = time;
    my $err   = dies { $sub->subscribe };
    my $elapsed = time - $start;

    like(
        $err,
        qr/Timed out waiting for runner socket .* to accept connections/,
        "Runner::Subscriber croaks its connect-timeout instead of hanging on a wedged listener",
    );
    ok($elapsed < 15, "  ... and returns near its ~1s deadline (${elapsed}s), not a 30s+ hang");
};

done_testing;
