use Test2::V0;
use v5.38;

use Socket qw/AF_UNIX SOCK_STREAM PF_UNSPEC/;
use Scalar::Util qw/refaddr/;
use File::Temp qw/tempdir/;
use Time::HiRes qw/time/;

use Test2::Collector::Util::Socket qw/connect_unix/;
use Test2::Collector::Util::Zstd qw/compress_blob/;
use Test2::Collector::Util::Zstd::FrameBuffer();
use Test2::Harness2::Util::JSON qw/encode_json decode_json/;

use Test2::Harness2::Role::Service::Connection;

# #108: Role::Service must not treat EAGAIN as fatal. A slow subscriber/logger/
# stage under sustained frame traffic must NOT be dropped and must lose NO frames
# (they queue in the per-connection outbound buffer and are finished by a later
# non-blocking flush); only a genuinely-gone peer (EPIPE/ECONNRESET), a full
# zero-progress stall window, or an over-cap queue drops the peer. The offset
# invariant is the crux: a resumed write continues mid-buffer, never re-sending a
# partially-written frame from its start.

# A connected pair of non-blocking unix sockets.
sub pair {
    socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
    $_->blocking(0) for $a, $b;
    return ($a, $b);
}

sub mkconn {
    my ($fh, $id, %opts) = @_;
    return Test2::Harness2::Role::Service::Connection->new(
        fh          => $fh,
        my_identity => $id,
        outbound    => 0,
        %opts,
    );
}

# n bytes that zstd cannot meaningfully compress (prefer /dev/urandom, fall back
# to a PRNG) so a frame reliably exceeds the socket send buffer.
sub incompressible {
    my ($n) = @_;
    my $data = '';
    if (open(my $ur, '<:raw', '/dev/urandom')) {
        while (length($data) < $n) {
            my $got = sysread($ur, my $chunk, $n - length($data));
            last unless $got;
            $data .= $chunk;
        }
        close $ur;
    }
    $data .= pack('N', int(rand(2**32))) while length($data) < $n;
    substr($data, $n) = '' if length($data) > $n;
    return $data;
}

# ---------------------------------------------------------------------------
# 1. Ordered mid-frame resume: a slow subscriber under sustained traffic drops
#    nothing and loses nothing, and a resumed flush continues at the exact next
#    unwritten byte (proves the offset invariant).
# ---------------------------------------------------------------------------
subtest ordered_resume => sub {
    my ($fa, $fb) = pair();
    my $a = mkconn($fa, 'A', owner_flushes => 1);    # service-owned; non-blocking flush

    # A modest incompressible pad makes each frame a few hundred bytes so the
    # socket buffer fills after a manageable number of frames.
    my $pad = unpack('H*', incompressible(256));

    my $frame = sub ($seq) { compress_blob(encode_json({transition => {seq => $seq, pad => $pad}})) };

    # Send until the socket back-pressures (WBUF retains bytes: EAGAIN), never
    # reading peer B -- nothing may be dropped while B is merely not reading.
    my $n = 0;
    while (!$a->pending_out) {
        $n++;
        $a->send_raw($frame->($n));
        die "socket never back-pressured after $n frames" if $n > 200_000;
    }
    ok($a->pending_out, "outbound buffer retained bytes once the peer stopped draining");

    # 50 more on top of the already-full buffer.
    for (1 .. 50) { $n++; $a->send_raw($frame->($n)) }
    my $N = $n;

    ok(!$a->closed, "a merely-slow subscriber is NOT dropped ($N frames queued)");

    # Now drain B while flushing A until the whole buffer is delivered. If a
    # partially-written frame were ever re-sent from its start the zstd stream
    # would corrupt and decode would gap/dup/croak.
    my $fbuf = Test2::Collector::Util::Zstd::FrameBuffer->new;
    my @seqs;
    my $collect = sub {
        my $ok = eval {
            for my $rec ($fbuf->drain) {
                my $p = decode_json($rec->{payload});
                push @seqs, $p->{transition}{seq} if $p->{transition};
            }
            1;
        };
        return $ok || $@;
    };

    my $deadline = time + 20;
    while (@seqs < $N) {
        $a->flush_writes;
        my $buf = '';
        my $r = sysread($fb, $buf, 65536);
        if (defined($r) && $r) {
            $fbuf->push_bytes($buf);
            my $res = $collect->();
            unless ($res eq 1) { ok(0, "decode error (offset resume broke the frame stream): $res"); last }
        }
        if (time > $deadline) { ok(0, "timed out draining frames (got ${\ scalar @seqs}/$N)"); last }
    }

    ok(!$a->closed, "connection stayed live through the whole slow drain");
    is(\@seqs, [1 .. $N], "every frame arrived exactly once, in order (no gap/dup/resend)");
};

# ---------------------------------------------------------------------------
# 5. Client bounded-blocking: a default-mode (non-owner_flushes) conn whose peer
#    never reads gives backpressure -- send_raw returns 0 and closes after the
#    stall window, bounded (no hang).
# ---------------------------------------------------------------------------
subtest client_bounded_blocking => sub {
    my ($fa, $fb) = pair();
    my $a = mkconn($fa, 'A', stall_timeout => 0.2);    # default mode: blocking flush
    # $fb is never read.

    my $start = time;
    my $ret   = $a->send_raw('x' x (4 * 1024 * 1024));
    my $el    = time - $start;

    is($ret, 0, "send_raw reports non-delivery when the peer will not drain");
    ok($a->closed, "the connection is closed after the bounded blocking flush");
    ok($el >= 0.2,  "it blocked for at least the stall window (backpressure): ${el}s");
    ok($el < 2,     "but returned bounded, no hang: ${el}s");
};

# ---------------------------------------------------------------------------
# 4. Genuinely-gone peer drops promptly via the EPIPE path -- no stall wait.
# ---------------------------------------------------------------------------
subtest dead_peer_prompt => sub {
    my ($fa, $fb) = pair();
    my $a = mkconn($fa, 'A', owner_flushes => 1, stall_timeout => 5);

    close($fb);    # peer is entirely gone

    my $start = time;
    my $ret   = $a->send_raw('x' x (300 * 1024));
    $a->flush_writes;
    my $el = time - $start;

    is($ret, 0, "send_raw reports the write did not land");
    ok($a->closed, "a gone peer (EPIPE/ECONNRESET) is dropped");
    ok($el < 1, "dropped promptly, well before the 5s stall window: ${el}s");
};

# ---------------------------------------------------------------------------
# 3. Trickle survives: a reader that makes steady small progress is never
#    stall-dropped, even though the buffer stays non-empty the whole time.
# ---------------------------------------------------------------------------
subtest trickle_survives => sub {
    my ($fa, $fb) = pair();
    my $a = mkconn($fa, 'A', owner_flushes => 1, stall_timeout => 0.3);

    # Fill well past the socket buffer so the WBUF cannot drain in 1s of trickle.
    $a->send_raw(incompressible(256 * 1024)) for 1 .. 5;
    ok($a->pending_out, "outbound buffer is backed up after the fill");

    my $t0 = time;
    while (time - $t0 < 1.0) {
        sysread($fb, my $buf, 4096);    # steady small progress
        $a->flush_writes;
        Time::HiRes::sleep(0.1);
    }

    ok(!$a->closed,       "a steadily-progressing (slow) reader is never dropped");
    ok(!$a->wbuf_expired, "the stall deadline never fires while progress is made");
    ok($a->pending_out,   "and there is still buffered data (it was genuinely slow)");
};

# ---------------------------------------------------------------------------
# 2. Wedge drop, peers stay live: under a real Role::Service, one stalled
#    subscriber is dropped after its stall window while OTHER subscribers keep
#    receiving, and no service_io tick ever blocks.
# ---------------------------------------------------------------------------
subtest wedge_drop_peers_live => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $hub = My::Hub->new(workdir => $dir, name => 'runner');
    $hub->start_service;
    my $path = $hub->service_socket_path;

    # Two client subscribers, both dialing the hub.
    my ($fc1, $fc2) = (connect_unix($path), connect_unix($path));
    $_->blocking(0) for $fc1, $fc2;
    my $c1 = Test2::Harness2::Role::Service::Connection->new(fh => $fc1, my_identity => 'sub1', outbound => 1);
    my $c2 = Test2::Harness2::Role::Service::Connection->new(fh => $fc2, my_identity => 'sub2', outbound => 1);

    # Handshake + subscribe both.
    my ($s1, $s2) = (0, 0);
    for (1 .. 100) {
        $hub->service_io;
        $c1->drain;
        $c2->drain;
        if ($c1->ready && !$s1) { $c1->send_request('subscribe'); $s1 = 1 }
        if ($c2->ready && !$s2) { $c2->send_request('subscribe'); $s2 = 1 }
        last if $s1 && $s2 && keys(%{$hub->{service_subs}}) == 2;
        Time::HiRes::sleep(0.01);
    }
    is(scalar keys %{$hub->{service_subs}}, 2, "both subscribers registered on the hub");

    my $hs1 = $hub->service_peer_conn('sub1');
    my $hs2 = $hub->service_peer_conn('sub2');
    ok($hs1 && $hs2, "hub-side connections resolved for both subscribers");
    my $hs2fh = $hs2->fh;

    # Stall sub2: a tight window, and we will never read fc2.
    $hs2->{stall_timeout} = 0.2;

    # An incompressible, JSON-safe pad so each forwarded frame reliably exceeds
    # the socket send buffer and back-pressures the wedged subscriber fast.
    my $pad = unpack('H*', incompressible(256 * 1024));

    my @seqs1;
    my @io_times;
    my $seq            = 0;
    my $dropped_at_seq = undef;

    my $read_c1 = sub {
        push @seqs1, map { $_->{payload}{transition}{seq} }
            grep { $_->{kind} eq 'transition' } $c1->drain;
    };

    my $t0 = time;
    while (time - $t0 < 3) {
        $seq++;
        $hub->forward_frame(compress_blob(encode_json({transition => {seq => $seq, pad => $pad}})));

        my $ts = time;
        $hub->service_io;
        push @io_times, time - $ts;

        $read_c1->();

        $dropped_at_seq //= $seq if $hs2->closed;
        last if defined $dropped_at_seq && $seq > $dropped_at_seq + 5;

        Time::HiRes::sleep(0.05);
    }

    ok(defined $dropped_at_seq, "the wedged subscriber was dropped within the window");
    ok($hs2->closed, "stalled connection is closed");
    ok(!$hub->service_peer_conn('sub2'), "stalled peer removed from the peer registry");
    ok(!$hub->{service_subs}{$hs2}, "stalled peer removed from the subscriber set");
    my $addr = refaddr($hs2fh);
    ok(!(grep { refaddr($_) == $addr } $hub->{service_select}->handles), "stalled fh removed from the select set");

    # The healthy subscriber must still receive frames sent AFTER the drop.
    my $deadline = time + 5;
    while (!(grep { defined($dropped_at_seq) && $_ > $dropped_at_seq } @seqs1) && time < $deadline) {
        $hub->service_io;
        $read_c1->();
        Time::HiRes::sleep(0.01);
    }
    ok((grep { defined($dropped_at_seq) && $_ > $dropped_at_seq } @seqs1),
        "the healthy subscriber kept receiving frames after the other was dropped");

    # No service_io tick ever blocked on the stalled peer (the liveness invariant).
    my $max = (sort { $b <=> $a } @io_times)[0] // 0;
    ok($max < 0.19, "no service_io tick blocked near the 0.2s stall window (max=${max}s)");

    $hub->close_service;
};

done_testing;

# A minimal Role::Service consumer: it accepts subscribers and forwards frames to
# them, mirroring Test2::Harness2::Runner's hub wiring without the full runner.
BEGIN {
    package My::Hub;
    use v5.38;
    use Object::HashBase qw/<workdir <name/;
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Service';

    sub request_handler_subscribe ($self, $payload, $conn) {
        $self->add_subscriber($conn) if defined $conn;
        return {ok => 1};
    }
}
