use Test2::V0;
use v5.38;

use Socket qw/AF_UNIX SOCK_STREAM PF_UNSPEC/;

use Test2::Harness2::Util::FdPass::Control;

# Chunk 13 / ticket #39: the dedicated `yath spawn` control mini-protocol that
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

done_testing;
