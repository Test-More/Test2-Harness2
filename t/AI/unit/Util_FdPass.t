use v5.38;

use Test2::V0;

use POSIX ();
use Errno qw/EINTR/;
use Socket qw/AF_UNIX SOCK_STREAM PF_UNSPEC/;
use Time::HiRes ();

use Test2::Harness2::Util::FdPass qw{
    fdpass_available
    require_fdpass
    send_fds
    recv_fds
    command_listen
    target_connect
};

# fdpass_available() and require_fdpass() are always exercisable: they only
# report on whether IO::FDPass loaded. The descriptor-passing assertions below
# need the real module, so they are gated on availability and skip_all'd when it
# is missing.
my $have = fdpass_available();

ok(defined($have), "fdpass_available() returns a defined boolean");

if ($have) {
    ok(lives { require_fdpass() }, "require_fdpass() lives when IO::FDPass is present")
        or note($@);
}
else {
    like(
        dies { require_fdpass('yath spawn') },
        qr/yath spawn requires the IO::FDPass module/,
        "require_fdpass() dies with an actionable, feature-named message when absent",
    );

    my ($probe_a) = _make_socketpair();
    like(
        dies { send_fds($probe_a, [0]) },
        qr/requires the IO::FDPass module/,
        "send_fds() refuses cleanly (no raw load crash) when IO::FDPass is absent",
    );

    # IO::FDPass is absent: the descriptor-passing round-trip below cannot run; the
    # guard assertions above ARE the absent-path coverage. End cleanly here (skip_all
    # would conflict with the assertions already run above).
    done_testing;
    exit 0;
}

# A connected pair of unix sockets used as the transport for the fd passing.
sub _make_socketpair {
    socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
        or die "socketpair failed: $!";
    return ($a, $b);
}

subtest argument_validation => sub {
    my ($a, $b) = _make_socketpair();

    like(dies { send_fds(undef, [0]) }, qr/socket required/, "send_fds requires a socket");
    like(dies { send_fds($a, undef) }, qr/fds arrayref required/, "send_fds requires an fds arrayref");
    like(dies { send_fds($a, []) }, qr/fds arrayref required/, "send_fds rejects an empty fds list");

    like(dies { recv_fds(undef, 1) }, qr/socket required/, "recv_fds requires a socket");
    like(dies { recv_fds($b, 0) }, qr/positive count required/, "recv_fds requires a positive count");
    like(dies { recv_fds($b, undef) }, qr/positive count required/, "recv_fds rejects an undef count");

    like(dies { target_connect(undef) }, qr/path required/, "target_connect requires a path");
};

subtest single_fd_round_trip => sub {
    # The descriptor we will pass: one end of a brand-new pipe. Proving the
    # received fd refers to the SAME open file description means a write into the
    # original write-end is readable from the received (duped) read-end.
    pipe(my $pipe_r, my $pipe_w) or die "pipe failed: $!";

    my ($snd, $rcv) = _make_socketpair();

    my $sent = send_fds($snd, [fileno($pipe_r)]);
    is($sent, 1, "send_fds reported 1 fd sent");

    my $fds = recv_fds($rcv, 1);
    is(ref($fds), 'ARRAY', "recv_fds returned an arrayref");
    is(scalar(@$fds), 1, "received exactly one fd");
    ok($fds->[0] >= 0, "received a valid (non-negative) fd number");
    isnt($fds->[0], fileno($pipe_r), "received fd is a fresh number, not the original");

    open(my $got_r, '<&=', $fds->[0]) or die "fdopen received fd failed: $!";

    # Same open file description check: write on the original pipe write-end,
    # read it back through the fd that travelled over the socket.
    syswrite($pipe_w, "hello-fdpass\n") or die "syswrite failed: $!";

    my $buf = '';
    sysread($got_r, $buf, 64);
    is($buf, "hello-fdpass\n", "data written to the original write-end arrived on the passed fd");
};

subtest multi_fd_round_trip_preserves_order => sub {
    # Pass three distinct read-ends; assert each received fd maps back to its own
    # write-end in order. This is the spawn case (STDIN/STDOUT/STDERR = 3 fds).
    my (@readers, @writers);
    for (0 .. 2) {
        pipe(my $r, my $w) or die "pipe failed: $!";
        push @readers => $r;
        push @writers => $w;
    }

    my ($snd, $rcv) = _make_socketpair();

    my $sent = send_fds($snd, [map { fileno($_) } @readers]);
    is($sent, 3, "send_fds reported 3 fds sent");

    my $fds = recv_fds($rcv, 3);
    is(scalar(@$fds), 3, "received exactly three fds");

    for my $i (0 .. 2) {
        open(my $got, '<&=', $fds->[$i]) or die "fdopen failed: $!";
        my $msg = "stream-$i\n";
        syswrite($writers[$i], $msg) or die "syswrite failed: $!";
        my $buf = '';
        sysread($got, $buf, 64);
        is($buf, $msg, "fd #$i round-tripped to the matching write-end (order preserved)");
    }
};

subtest command_listen_target_dial_choreography => sub {
    my ($listen, $path) = command_listen();

    ok($listen, "command_listen returned a listen handle");
    ok(defined($path) && length($path), "command_listen returned a socket path");
    ok(-S $path, "the returned path is a unix socket");

    my $mode = (stat $path)[2] & 07777;
    is($mode, 0600, "listen socket is mode 0600");

    # The command listens, the target dials back, the command passes the fd over
    # the accepted connection, the target receives and installs it.
    pipe(my $pipe_r, my $pipe_w) or die "pipe failed: $!";

    my $pid = fork // die "fork failed: $!";
    if (!$pid) {
        # Target: dial in, receive the fd, write a token through it, exit.
        close($listen);
        my $ok = eval {
            my $sock = target_connect($path);
            my $fds  = recv_fds($sock, 1);
            open(my $w, '>&=', $fds->[0]) or die "fdopen failed: $!";
            syswrite($w, "via-choreography\n") or die "syswrite failed: $!";
            1;
        };
        POSIX::_exit($ok ? 0 : 1);
    }

    # Command: accept the dial-back and pass the pipe write-end.
    my $conn = $listen->accept or die "accept failed: $!";
    send_fds($conn, [fileno($pipe_w)]);

    my $buf = '';
    sysread($pipe_r, $buf, 64);
    is($buf, "via-choreography\n", "fd passed over the listen/dial choreography reaches the command");

    waitpid($pid, 0);
    is($? >> 8, 0, "target child completed cleanly");
};

# Ticket #139 (finding G3): IO::FDPass::recv returns -1 on peer EOF WITHOUT setting
# errno. With a STALE EINTR in $! (inherited across fork from the stage host's
# signal-handling IPC) the old `next if $! == EINTR` retry spun forever at 100% CPU
# in a detached supervisor. recv_fds now clears errno before each recv, so an EOF
# with a stale EINTR is classified as a close (fast croak, no spin, no stale text).
subtest recv_fds_eof_with_stale_eintr_does_not_spin => sub {
    my ($a, $b) = _make_socketpair();
    close($b);    # peer closed -> recv returns -1 (EOF) without touching errno

    my $recv_err;
    my $bounded = eval {
        local $SIG{ALRM} = sub { die "TIMEOUT: recv_fds spun on a stale EINTR\n" };
        alarm 10;
        $! = EINTR;    # stale errno set BEFORE the call, as if inherited
        my $lived = eval { recv_fds($a, 1); 1 };
        $recv_err = $@;
        alarm 0;
        1;
    };
    my $outer = $@;
    alarm 0;

    ok($bounded, "recv_fds returned within the alarm window (did not spin at 100% CPU)")
        or diag($outer);
    like(
        $recv_err,
        qr/sender closed before sending all fds/,
        "recv_fds croaks with the EOF message (not stale errno text) despite a spurious EINTR in \$!",
    );
};

subtest send_fds_dead_peer_croaks_no_spin => sub {
    my ($a, $b) = _make_socketpair();
    close($b);    # peer gone

    # This ticket does NOT yet add the SIGPIPE guard to send_fds (#134 owns that), so
    # ignore SIGPIPE here to keep the dead-peer send from killing the test; the send
    # then surfaces as EPIPE in errno (!= EINTR) -> a clean croak, not a spin.
    local $SIG{PIPE} = 'IGNORE';

    pipe(my $pr, my $pw) or die "pipe: $!";

    my $send_err;
    my $bounded = eval {
        local $SIG{ALRM} = sub { die "TIMEOUT: send_fds spun on a dead peer\n" };
        alarm 10;
        $! = EINTR;    # stale errno again
        my $lived = eval { send_fds($a, [fileno($pr)]); 1 };
        $send_err = $@;
        alarm 0;
        1;
    };
    my $outer = $@;
    alarm 0;

    ok($bounded, "send_fds returned within the alarm window (did not spin)") or diag($outer);
    like($send_err, qr/failed to send fd/, "send_fds croaks on a dead peer (did not busy-loop on stale EINTR)");
};

done_testing;
