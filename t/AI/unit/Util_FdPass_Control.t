use Test2::V0;
use v5.38;

use Socket qw/AF_UNIX SOCK_STREAM PF_UNSPEC/;
use Fcntl qw/F_GETFL O_NONBLOCK/;

use Test2::Harness2::Util::FdPass::Control;

# Chunk 13 / ticket TODO-39: the dedicated `yath spawn` control mini-protocol that
# rides the same socket AFTER the SCM_RIGHTS descriptor pass. It is intentionally
# NOT Role::Service::Connection (no identity frame to collide with the fd-pass
# byte). This exercises the framing round-trip over a real socketpair plus the EOF
# semantics the supervisor relies on.

sub pair {
    socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
    return ($a, $b);
}

subtest message_roundtrip => sub {
    my ($a, $b) = pair();

    my $sup = Test2::Harness2::Util::FdPass::Control->new(fh => $a);
    my $cmd = Test2::Harness2::Util::FdPass::Control->new(fh => $b);

    # supervisor -> command: hello with the supervisor pid
    ok($sup->send_hello(4242), "sent hello");
    my $hello = $cmd->read_message;
    is($hello->{hello}{pid}, 4242, "command read the supervisor pid");

    # command -> supervisor: forwarded signal
    ok($cmd->send_signal('INT'), "sent a forwarded signal");
    my $sig = $sup->read_message;
    is($sig->{signal}{signal}, 'INT', "supervisor read the forwarded signal name");

    # supervisor -> command: raw wait status at exit
    my $raw = (3 << 8) | 0;    # exit code 3, no signal
    ok($sup->send_exit_status($raw), "sent the raw wait status");
    my $exit = $cmd->read_message;
    is($exit->{exit_status}{status}, $raw, "command read the raw wait status");
};

subtest multiple_frames_in_one_read => sub {
    # Several frames written back to back must each decode in order (length-prefixed
    # framing on the stream).
    my ($a, $b) = pair();

    my $sup = Test2::Harness2::Util::FdPass::Control->new(fh => $a);
    my $cmd = Test2::Harness2::Util::FdPass::Control->new(fh => $b);

    $sup->send_hello(1);
    $sup->send_exit_status(256);

    my $m1 = $cmd->read_message;
    my $m2 = $cmd->read_message;

    is($m1->{hello}{pid},          1,   "first frame is the hello");
    is($m2->{exit_status}{status}, 256, "second frame is the exit status");
};

subtest eof_on_peer_close => sub {
    # The supervisor watches for EOF (the command/terminal died). When the command
    # side closes, read_message returns nothing and closed() becomes true.
    my ($a, $b) = pair();

    my $sup = Test2::Harness2::Util::FdPass::Control->new(fh => $a);
    my $cmd = Test2::Harness2::Util::FdPass::Control->new(fh => $b);

    $cmd->close;

    my @msg = $sup->read_message;
    is(scalar(@msg), 0, "read_message returns empty on EOF");
    ok($sup->closed, "channel is closed after peer EOF");
};

subtest nonblocking_read => sub {
    my ($a, $b) = pair();

    my $sup = Test2::Harness2::Util::FdPass::Control->new(fh => $a);
    my $cmd = Test2::Harness2::Util::FdPass::Control->new(fh => $b);

    my @nothing = $cmd->read_message_nb;
    is(scalar(@nothing), 0, "non-blocking read returns nothing when idle");
    ok(!$cmd->closed, "channel still open when merely idle");

    $sup->send_hello(99);
    my $msg = $cmd->read_message_nb;
    is($msg->{hello}{pid}, 99, "non-blocking read returns a buffered frame");
};

# Ticket TODO-139 (finding 6+G2): the fast-exit ORDERING crux. The supervisor can send
# its exit_status frame and close the socket in one burst, so the frame and EOF
# arrive together. read_message MUST drain the buffered frame before it ever
# classifies EOF -- take-before-fill -- or the command would misreport a healthy exit
# as a "vanish". This replicates the exact bridge_io read loop (spawn.pm) against a
# Control pair where the writer has ALREADY sent everything and closed.
subtest fast_exit_ordering_frame_before_eof => sub {
    my ($a, $b) = pair();

    my $sup = Test2::Harness2::Util::FdPass::Control->new(fh => $a);
    my $cmd = Test2::Harness2::Util::FdPass::Control->new(fh => $b);

    my $raw = 3 << 8;    # exit code 3, no signal
    $sup->send_hello($$);
    $sup->send_exit_status($raw);
    $sup->close;         # writer gone: EOF is pending behind the two buffered frames

    my $hello = $cmd->read_message;
    is($hello->{hello}{pid}, $$, "hello read first");

    # The bridge_io loop verbatim: exit_status test BEFORE the closed-break, and the
    # closed-break requires !$msg.
    my ($status, $got_exit) = (0, 0);
    while (1) {
        my $msg = $cmd->read_message;
        if ($msg && $msg->{exit_status}) {
            $status   = $msg->{exit_status}{status} // 0;
            $got_exit = 1;
            last;
        }
        last if $cmd->closed && !$msg;
    }

    ok($got_exit, "the exit_status frame was drained before EOF was classified");
    is($status, $raw, "the real wait status survived the frame+EOF burst (no false vanish)");
};

subtest vanish_when_no_exit_status => sub {
    my ($a, $b) = pair();

    my $sup = Test2::Harness2::Util::FdPass::Control->new(fh => $a);
    my $cmd = Test2::Harness2::Util::FdPass::Control->new(fh => $b);

    # Supervisor announces itself then vanishes (crash/OOM) with no exit_status.
    $sup->send_hello($$);
    $sup->close;

    my $hello = $cmd->read_message;
    ok($hello && $hello->{hello}, "hello read");

    my ($status, $got_exit) = (0, 0);
    while (1) {
        my $msg = $cmd->read_message;
        if ($msg && $msg->{exit_status}) {
            $status   = $msg->{exit_status}{status} // 0;
            $got_exit = 1;
            last;
        }
        last if $cmd->closed && !$msg;
    }

    ok(!$got_exit, "no exit_status frame -> the command classifies this as a vanish");
};

# Ticket TODO-139 mandatory vanish companion: _send must restore blocking mode. A prior
# read_message_nb leaves the fh O_NONBLOCK; without the restore a subsequent
# send_exit_status could fail EAGAIN (treated as fatal), dropping the final frame and
# turning a healthy exit into a spurious vanish.
subtest send_restores_blocking_after_nb_read => sub {
    my ($a, $b) = pair();

    my $sup = Test2::Harness2::Util::FdPass::Control->new(fh => $a);
    my $cmd = Test2::Harness2::Util::FdPass::Control->new(fh => $b);

    # read_message_nb on the supervisor side leaves $a non-blocking (_fill(0)).
    $sup->read_message_nb;
    my $flags_before = fcntl($a, F_GETFL, 0);
    ok(($flags_before & O_NONBLOCK), "read_message_nb left the fh non-blocking");

    ok($sup->send_exit_status(256), "send_exit_status returned true after a non-blocking read");

    my $flags_after = fcntl($a, F_GETFL, 0);
    ok(!($flags_after & O_NONBLOCK), "_send restored blocking mode on the fh");

    my $msg = $cmd->read_message;
    is($msg->{exit_status}{status}, 256, "the peer actually received the frame");
};

done_testing;
