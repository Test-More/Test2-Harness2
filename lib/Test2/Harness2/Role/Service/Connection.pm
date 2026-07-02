package Test2::Harness2::Role::Service::Connection;
use v5.38;

our $VERSION = '2.000000';

use Time::HiRes qw/time/;
use POSIX qw/:errno_h/;
use IO::Select ();

use Test2::Collector::Util::Zstd qw/compress_blob/;
use Test2::Collector::Util::Zstd::FrameBuffer();
use Test2::Harness2::Util::JSON qw/encode_json decode_json/;
use Test2::Harness2::Util::UUID qw/gen_uuid/;

use Test2::Harness2::Util::HashBase qw{
    <fh
    <outbound
    <my_identity
    <identity_timeout
    <owner_flushes
    <stall_timeout
    <max_wbuf
    +wbuf
    +wbuf_deadline
    +fb
    +identity
    +identity_pid
    +identity_payload
    +ready
    +sent_identity
    +deadline
    +bad
    +pending
    +closed
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Role::Service::Connection - One framed, bidirectional, identified
socket connection between two harness endpoints.

=head1 DESCRIPTION

The transport every harness endpoint -- services (runner, preload stages, the
future system-load service) and command clients alike -- uses for one socket
connection (ARCHITECTURE.md §5.2). It owns the wire protocol so the
request/response correlation, the identity exchange, and the bad-frame policy live
in B<one> place rather than being re-implemented per client.

=head2 Protocol

Every message is a JSON object, zstd-compressed into one self-contained frame.
Five frame kinds, distinguished by their top-level key:

    { identity   => { name => $id, pid => $$, ... } }   # who I am
    { request    => { request_id => $uuid, command => $cmd, ... } }
    { response   => { request_id => $uuid, ... } }
    { transition => ... }                     # collector transition (folded)
    { facet_data => { ... } }                 # collector event/transition

There is B<no ordering assumption>: an endpoint may send a request and then
receive unrelated messages (other requests, transitions, even an unrelated
response) before the response to its own request arrives. Responses are matched to
requests by C<request_id>, never by arrival order. Collector C<transition> /
C<facet_data> frames are produced by the external collector reporters and are
passed through unchanged; everything else the harness sends is a request or a
response.

=head2 Lifecycle

A connection that B<dials> (C<outbound>) a peer sends its identity immediately; a
connection that B<accepts> replies with its identity once it has seen the peer's.
B<Every> connection must identify first -- there is no exemption: a one-way
collector reporter announces an identity too (via the recorder's preamble) and
discards the identity reply it gets back. Until it is established a connection is
B<pending>, and only an C<identity> frame is accepted; B<anything else> as the
first frame (a transition, a request, a response, or a corrupt frame) means a bad
connection and is closed at once.

If no identity arrives before the timeout the pending connection is dropped. Once
established, B<3 corrupt / invalid frames in a row> (with no valid frame between
them) close the connection; any valid frame resets the count. A second identity on
an established peer counts as invalid.

=head1 ATTRIBUTES

=over 4

=item $fh = $conn->fh

The underlying socket filehandle.

=item $bool = $conn->outbound

True when this side dialed the connection (vs accepted it).

=item $id = $conn->my_identity

The identity this side announces.

=item $secs = $conn->identity_timeout

How long (seconds) to wait for the peer's identity before declaring the connection
bad. Defaults to 5.

=item $bool = $conn->owner_flushes

True when an external loop (the service's C<service_io>) owns finishing this
connection's writes: C<send_raw> only makes one non-blocking flush attempt and
leaves any leftover bytes queued for a later tick, so one stalled peer never
blocks the byte-pump. When false (client-side conns, which have no such loop) a
C<send_raw> finishes with a bounded-blocking flush instead, giving submission
backpressure. Defaults to false.

=item $secs = $conn->stall_timeout

The zero-progress stall window (seconds) before a wedged peer is dropped. The
deadline is armed only while the peer accepts B<zero> bytes; any C<< >=1 >>-byte
write clears it, so a merely-slow (trickling) reader is never dropped. Defaults
to 10.

=item $bytes = $conn->max_wbuf

The outbound-buffer cap (bytes). A C<send_raw> that would grow the queue past this
drops the peer instead of buffering unbounded memory for one that cannot keep up.
Defaults to 16 MiB.

=back

=head1 PUBLIC METHODS

=over 4

=item $id = $conn->identity

The peer's announced identity, or C<undef> until it has arrived.

=item $pid = $conn->peer_pid

The peer process's pid, announced alongside its identity, or C<undef> until the
identity frame has arrived. This is the authoritative source for a connected
peer's real pid (e.g. a preload stage's pid for C<status>/C<ps>).

=item $hashref = $conn->identity_payload

The B<full> identity hash the peer announced (C<name>, C<pid>, and any extra
fields a reporter carries -- a test collector announces C<job_id>, C<job_try>,
and C<run_id>), or C<undef> until the identity frame has arrived. The runner uses
the extra fields to map a connection (and its EOF) back to the job it ran.

=item $bool = $conn->ready

True once the peer's identity has been received (the connection may carry
requests/responses).

=item $bool = $conn->closed

True once the connection has been dropped (bad protocol, EOF, or an explicit
C<close>).

=item $bool = $conn->expired

True when the connection is still pending identity past its timeout.

=item $conn->send_identity

Send this side's identity frame (once; a no-op if already sent).

=item $request_id = $conn->send_request($command, %args)

Send a request and remember it as outstanding. Returns the generated
C<request_id> so the caller can match the eventual response.

=item $conn->send_response($request_id, $payload)

Send a response to a request, echoing its C<request_id>.

=item $bool = $conn->send_control($control, %args)

Send one inbound control message to a collector reporter that was built to read
controls (a single C<< {control =E<gt> {control =E<gt> $control, %args}} >> frame
typed C<control>). Used for the runner's bail/abort B<terminate> message. Returns
false if the connection is (or becomes) closed, true on a successful write. There
is no reply -- the collector kills its child and exits, EOFing its connection.

=item $bool = $conn->send_raw($bytes)

Queue one already-framed (compressed) blob on the per-connection outbound buffer
and flush. Every send path (identity, request, response, control, forwarded
frame) funnels through here, so per-connection frame order is preserved in one
FIFO. On an C<owner_flushes> connection it makes a single non-blocking flush
attempt and leaves any remainder queued for C<service_io>; otherwise it finishes
with a bounded-blocking flush. Returns true when the bytes are queued/sent on a
live connection, false once the connection is (or becomes) closed -- which happens
only on a vanished peer (EPIPE/ECONNRESET), a full C<stall_timeout> of zero
progress, or the queue exceeding C<max_wbuf>. Never croaks.

=item $bool = $conn->flush_writes

Write as much of the outbound buffer as the socket accepts, without blocking.
Returns true when the buffer is empty, false when bytes remain (EAGAIN, buffer
still queued) or the connection closed. Bytes leave the buffer only B<after>
C<syswrite> reports them written and are consumed from the front, so a resumed
flush always continues at the exact next unwritten byte of a partially-written
frame -- a partial frame is never re-sent from its start.

=item $bool = $conn->pending_out

True while the outbound buffer still holds unwritten bytes.

=item $bool = $conn->wbuf_expired

True once the connection has queued bytes and has made B<zero> write progress for
a full C<stall_timeout> window (a wedged, not merely slow, peer). Any successful
write clears the armed deadline, so a trickling reader never expires.

=item @events = $conn->drain

Read whatever bytes are available (non-blocking), decode complete frames, apply
the lifecycle/bad-frame policy, and return a list of classified events for the
owner to act on. Each event is a hashref:

    { kind => 'identity', name => $id }
    { kind => 'request',  request_id => $uuid, command => $cmd, payload => $hash }
    { kind => 'response', request_id => $uuid, payload => $hash }
    { kind => 'transition', payload => $hash, frame => $raw }

A C<response> whose C<request_id> matches no outstanding request is discarded (a
fire-and-forget reply), not returned. When the policy drops the connection
C<closed> becomes true; the owner should then forget it.

=item $conn->close

Close the filehandle and mark the connection closed (idempotent).

=back

=cut

sub init ($self) {
    $self->{+FB}      //= Test2::Collector::Util::Zstd::FrameBuffer->new;
    $self->{+PENDING} //= {};
    $self->{+BAD}     = 0;
    $self->{+READY}   = 0;
    $self->{+CLOSED}  = 0;
    # Bounds a peer that connects but never identifies at all. The service reads
    # before it checks expiry (see Role::Service::service_io), so a slow-but-present
    # identity is always read before this can fire -- this only catches a genuinely
    # silent / stuck peer, never a busy-loop timing gap.
    $self->{+DEADLINE} = time + ($self->{+IDENTITY_TIMEOUT} // 5);

    # The outbound buffer must exist before send_identity below queues through it.
    $self->{+WBUF}          //= '';
    $self->{+STALL_TIMEOUT} //= 10;
    $self->{+MAX_WBUF}      //= 16 * 1024 * 1024;

    # A dialer announces itself immediately; an accepter waits and replies once it
    # has seen the peer's identity.
    $self->send_identity if $self->{+OUTBOUND};

    return;
}

sub identity         { $_[0]->{+IDENTITY} }
sub peer_pid         { $_[0]->{+IDENTITY_PID} }
sub identity_payload { $_[0]->{+IDENTITY_PAYLOAD} }
sub ready            { $_[0]->{+READY}  ? 1 : 0 }
sub closed   { $_[0]->{+CLOSED} ? 1 : 0 }

sub expired ($self) {
    return 0 if $self->{+READY};
    return 0 if $self->{+CLOSED};
    return time > $self->{+DEADLINE} ? 1 : 0;
}

sub send_identity ($self) {
    return if $self->{+SENT_IDENTITY};
    $self->{+SENT_IDENTITY} = 1;
    $self->_write({identity => {name => $self->{+MY_IDENTITY}, pid => $$}});
    return;
}

sub send_request ($self, $command, %args) {
    return undef if $self->{+CLOSED};

    my $request_id = gen_uuid();
    $self->{+PENDING}{$request_id} = 1;
    $self->_write({request => {%args, request_id => $request_id, command => $command}});

    # _write closes the connection on a failed write (e.g. the peer is gone). Report
    # the failure so callers (service_send) can treat it as "not delivered".
    return undef if $self->{+CLOSED};

    return $request_id;
}

sub send_response ($self, $request_id, $payload = {}) {
    $self->_write({response => {%$payload, request_id => $request_id}});
    return;
}

sub send_control ($self, $control, %args) {
    return 0 if $self->{+CLOSED};

    # The runner-&gt;collector terminate is a single zstd frame typed 'control'
    # (the wire form Test2::Collector::Recorder::Socket reads when built with
    # read_control). It is fire-and-forget: the collector kills its child and
    # exits (its connection EOFs); there is no reply.
    $self->send_raw(compress_blob(encode_json({control => {control => $control, %args}})));

    return $self->{+CLOSED} ? 0 : 1;
}

sub pending_out ($self) { return length($self->{+WBUF} // '') ? 1 : 0 }

sub wbuf_expired ($self) {
    return 0 if $self->{+CLOSED};
    return 0 unless length($self->{+WBUF} // '');
    my $deadline = $self->{+WBUF_DEADLINE} or return 0;
    return time > $deadline ? 1 : 0;
}

# Queue one already-framed blob and flush. Service-owned conns (owner_flushes)
# flush opportunistically -- service_io finishes leftovers on later ticks;
# client conns block (bounded) until delivered, giving backpressure.
# Returns 1 if the bytes are queued/sent on a live conn, 0 if closed.
sub send_raw ($self, $bytes) {
    return 0 if $self->{+CLOSED};

    if (length($self->{+WBUF}) + length($bytes) > $self->{+MAX_WBUF}) {
        $self->close;    # peer too slow to be worth unbounded memory
        return 0;
    }
    $self->{+WBUF} .= $bytes;

    if ($self->{+OWNER_FLUSHES}) { $self->flush_writes }
    else                         { $self->_flush_blocking }

    return $self->{+CLOSED} ? 0 : 1;
}

# Non-blocking: write as much of the outbound buffer as the socket accepts.
# Returns 1 when the buffer is empty, 0 when bytes remain (EAGAIN) or the conn
# closed. NEVER blocks and NEVER re-sends a byte: written bytes are consumed
# from the FRONT of the buffer, so a resumed flush always continues at the
# exact next unwritten byte of a partially-written frame.
sub flush_writes ($self) {
    return 0 if $self->{+CLOSED};
    return 1 unless length($self->{+WBUF} // '');

    my $fh = $self->{+FH};
    unless (defined fileno($fh)) { $self->close; return 0 }

    # A vanished reader turns the write into SIGPIPE; surface it as EPIPE.
    local $SIG{PIPE} = 'IGNORE';

    while (length $self->{+WBUF}) {
        my $sent = syswrite($fh, $self->{+WBUF});

        unless (defined $sent) {
            next if $! == EINTR;
            if ($! == EAGAIN || $! == EWOULDBLOCK) {
                # Zero progress: arm the stall deadline once (progress clears it).
                $self->{+WBUF_DEADLINE} //= time + $self->{+STALL_TIMEOUT};
                return 0;
            }
            $self->close;    # EPIPE/ECONNRESET/...: peer is gone
            return 0;
        }

        unless ($sent) {    # defensive: treat a 0-byte write like EAGAIN
            $self->{+WBUF_DEADLINE} //= time + $self->{+STALL_TIMEOUT};
            return 0;
        }

        # Consume exactly what the kernel took; the offset never rewinds.
        substr($self->{+WBUF}, 0, $sent, '');
        delete $self->{+WBUF_DEADLINE};    # progress resets the stall clock
    }

    return 1;
}

sub close ($self) {
    return if $self->{+CLOSED};
    $self->{+CLOSED} = 1;
    eval { CORE::close($self->{+FH}); 1 };
    return;
}

sub drain ($self) {
    return () if $self->{+CLOSED};

    my $fh  = $self->{+FH};
    my $buf = '';
    my $n   = sysread($fh, $buf, 65536);

    unless (defined $n) {
        # A retryable would-block: nothing to read right now.
        return () if $! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR;
        # A fatal read error (e.g. ECONNRESET): the connection is dead, drop it so
        # the owner stops waiting on it.
        $self->close;
        return ();
    }

    if ($n == 0) {    # EOF
        $self->close;
        return ();
    }

    $self->{+FB}->push_bytes($buf);

    my @events;
    for my $rec ($self->{+FB}->drain) {
        my $payload;
        my $ok = eval { $payload = decode_json($rec->{payload}); 1 };

        unless ($ok && ref($payload) eq 'HASH') {
            last if $self->_bad_frame;    # closed
            next;
        }

        my $event = $self->_classify($payload, $rec);
        last if $self->{+CLOSED};
        push @events => $event if $event;
    }

    return @events;
}

=head1 PRIVATE METHODS

=over 4

=item $self->_write($message)

Frame, compress, and C<send_raw> one message hashref onto the outbound buffer.
The message is queued (and flushed per the connection's C<owner_flushes> mode);
the connection is closed only when the peer is gone, wedged past C<stall_timeout>,
or the queue exceeds C<max_wbuf> -- not on a transient EAGAIN.

=item $bool = $self->_flush_blocking

Client-side finish for a non-C<owner_flushes> connection: block (select-for-
writable) until the outbound buffer drains, the connection closes, or the peer
makes zero progress for a full C<stall_timeout> window. Provides submission
backpressure without an owning loop.

=item $event = $self->_classify($payload, $rec)

Apply the lifecycle / bad-frame policy to one decoded frame and return the
owner-facing event hashref (or C<undef> when the frame is consumed internally --
identity, an unmatched response, or a bad frame).

=item $bool = $self->_bad_frame

Account one corrupt / invalid frame: drop a still-pending connection immediately
(nothing legitimate precedes identity), else bump the consecutive-bad counter and
close at three. Returns true when it closed the connection.

=back

=cut

sub _write ($self, $message) {
    return if $self->{+CLOSED};
    $self->send_raw(compress_blob(encode_json($message)));
    return;
}

# Client-side finish: wait (select-for-writable) until the buffer drains, the
# conn closes, or the peer makes zero progress for a full stall window.
sub _flush_blocking ($self) {
    my $sel;
    while (1) {
        return 1 if $self->flush_writes;    # buffer empty
        return 0 if $self->{+CLOSED};

        if ($self->wbuf_expired) {          # zero progress for stall_timeout secs
            $self->close;
            return 0;
        }

        $sel //= IO::Select->new($self->{+FH});
        $sel->can_write(0.25);              # wakes early on writability
    }
}

sub _classify ($self, $payload, $rec) {
    my $is_identity   = ref($payload->{identity}) eq 'HASH';
    my $is_request    = ref($payload->{request})  eq 'HASH';
    my $is_response   = ref($payload->{response}) eq 'HASH';
    my $is_transition = ref($payload->{facet_data}) eq 'HASH' || exists $payload->{transition};

    # --- pending: the first frame decides the connection's kind ---------------
    unless ($self->{+READY}) {
        if ($is_identity) {
            $self->{+READY}            = 1;
            $self->{+BAD}              = 0;
            $self->{+IDENTITY}         = $payload->{identity}{name};
            $self->{+IDENTITY_PID}     = $payload->{identity}{pid};
            $self->{+IDENTITY_PAYLOAD} = $payload->{identity};

            # The accepter replies with its own identity (the dialer already sent
            # its own, so this is a no-op there) -- UNLESS the peer asked us not to.
            # A one-way collector reporter sets no_reply: it never reads, so a reply
            # would sit unread in its socket buffer and, when the reporter closes,
            # turn the close into a TCP-RST that discards transitions the runner has
            # not yet read. Honoring no_reply leaves the reporter with nothing to
            # read, so it closes cleanly and loses no transitions.
            $self->send_identity unless $payload->{identity}{no_reply};

            return {kind => 'identity', name => $self->{+IDENTITY}, payload => $self->{+IDENTITY_PAYLOAD}};
        }

        # Every connection must identify first -- there is no reporter exemption.
        # A transition, request, response, or corrupt frame before identity is a bad
        # connection.
        $self->close;
        return undef;
    }

    # --- established peer ------------------------------------------------------
    if ($is_request) {
        my $req = $payload->{request};
        $self->{+BAD} = 0;
        return {kind => 'request', request_id => $req->{request_id}, command => $req->{command}, payload => $req};
    }

    if ($is_response) {
        my $res = $payload->{response};
        $self->{+BAD} = 0;
        my $id = $res->{request_id};
        # Unmatched response (fire-and-forget reply, or a late duplicate): a valid
        # frame, so it does not count as bad, but there is no waiter to hand it to.
        return undef unless defined $id && delete $self->{+PENDING}{$id};
        return {kind => 'response', request_id => $id, payload => $res};
    }

    if ($is_transition) {
        $self->{+BAD} = 0;
        return {kind => 'transition', payload => $payload, frame => $rec->{frame}};
    }

    # A second identity, or any unknown envelope, on an established peer is invalid.
    $self->_bad_frame;
    return undef;
}

sub _bad_frame ($self) {
    # Before identity nothing legitimate can arrive, so one bad frame is fatal.
    unless ($self->{+READY}) {
        $self->close;
        return 1;
    }

    return 0 if ++$self->{+BAD} < 3;
    $self->close;
    return 1;
}

1;

__END__

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
