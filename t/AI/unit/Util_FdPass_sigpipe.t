use Test2::V0;
use v5.38;

use Socket qw/AF_UNIX SOCK_STREAM PF_UNSPEC/;

use Test2::Harness2::Util::FdPass qw/send_fds fdpass_available/;
use Test2::Harness2::Util::FdPass::Control;

# TODO-134 finding 43: a peer that dies mid-handoff turns the write into SIGPIPE,
# which (without protection) kills the yath command or the supervisor -- orphaning
# the spawned process group. Control::_send and FdPass::send_fds each guard the
# write with local $SIG{PIPE} = 'IGNORE', so a vanished peer surfaces as a caught
# errno (return 0 / a catchable croak), never a signal death.
#
# We deliberately set the ambient disposition to DEFAULT so that if the guard were
# removed, the write would kill this test process (a hard failure) instead of
# silently passing.
$SIG{PIPE} = 'DEFAULT';

sub pair {
    socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
    return ($a, $b);
}

subtest control_send_survives_dead_peer => sub {
    my ($near, $far) = pair();
    close($far);    # the peer vanishes before we write

    my $ctl = Test2::Harness2::Util::FdPass::Control->new(fh => $near);

    my $ret;
    my $ok = eval { $ret = $ctl->send_hello($$); 1 };

    ok($ok, "send_hello returned normally (no SIGPIPE death, no exception)");
    is($ret, 0, "it reported failure (0) rather than a false success");
    ok($ctl->closed, "the control channel closed itself on the write failure");

    # If we got here at all, the process survived the broken-pipe write.
    ok(1, "test process survived the broken-pipe control write");
};

subtest send_fds_survives_dead_peer => sub {
    skip_all "IO::FDPass not available" unless fdpass_available();

    my ($near, $far) = pair();
    close($far);    # the receiver vanishes before we hand off

    open(my $payload, '<', '/dev/null') or die "open /dev/null: $!";

    my $err;
    my $ok = eval { send_fds($near, [fileno($payload)]); 1 };
    $err = $@;

    ok(!$ok, "send_fds to a dead peer failed");
    like($err, qr/send_fds: failed to send fd/, "it croaked catchably (errno path), not a signal death");

    # Reaching here proves no SIGPIPE killed the test process.
    ok(1, "test process survived the broken-pipe fd send");
};

done_testing;
