package Test2::Harness2::Role::Service::Connection;
use v5.38;

our $VERSION = '2.000000';

use Time::HiRes qw/time/;
use POSIX qw/:errno_h/;

use Test2::Collector::Util::Socket qw/write_frame/;
use Test2::Collector::Util::Zstd qw/compress_blob/;
use Test2::Collector::Util::Zstd::FrameBuffer();
use Test2::Harness2::Util::JSON qw/encode_json decode_json/;
use Test2::Harness2::Util::UUID qw/gen_uuid/;

use Test2::Harness2::Util::HashBase qw{
    <fh
    <outbound
    <my_identity
    <identity_timeout
    +fb
    +identity
    +ready
    +reporter
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

    { identity   => { name => $id, ... } }   # who I am
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
connection that B<accepts> sends its identity only in reply, once it has seen the
peer's identity (so it never sends identity to a one-way reporter that does not
speak the protocol). Each protocol peer thus sends its identity and expects one.

Until it is established a connection is B<pending>, and the first frame decides its
kind:

=over 4

=item * an C<identity> frame → a B<peer> (requests / responses / transitions),

=item * a C<transition> / C<facet_data> frame → a B<reporter> (a one-way collector
stream; no identity, transitions only),

=item * anything else (a request, a response, or a corrupt frame) → B<bad>, closed
at once.

=back

If no first frame arrives before the timeout the pending connection is dropped.
Once established, B<3 corrupt / invalid frames in a row> (with no valid frame
between them) close the connection; any valid frame resets the count. A peer that
sends a second identity, or a reporter that sends anything but a transition,
counts as invalid.

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

=back

=head1 PUBLIC METHODS

=over 4

=item $id = $conn->identity

The peer's announced identity, or C<undef> until it has arrived.

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
    $self->{+DEADLINE} = time + ($self->{+IDENTITY_TIMEOUT} // 5);

    # A dialer announces itself immediately; an accepter waits and replies only to
    # a peer's identity, so it never sends identity to a one-way reporter stream.
    $self->send_identity if $self->{+OUTBOUND};

    return;
}

sub identity { $_[0]->{+IDENTITY} }
sub ready    { $_[0]->{+READY}  ? 1 : 0 }
sub reporter { $_[0]->{+REPORTER} ? 1 : 0 }
sub closed   { $_[0]->{+CLOSED} ? 1 : 0 }

sub expired ($self) {
    return 0 if $self->{+READY};
    return 0 if $self->{+CLOSED};
    return time > $self->{+DEADLINE} ? 1 : 0;
}

sub send_identity ($self) {
    return if $self->{+SENT_IDENTITY};
    $self->{+SENT_IDENTITY} = 1;
    $self->_write({identity => {name => $self->{+MY_IDENTITY}}});
    return;
}

sub send_request ($self, $command, %args) {
    my $request_id = gen_uuid();
    $self->{+PENDING}{$request_id} = 1;
    $self->_write({request => {%args, request_id => $request_id, command => $command}});
    return $request_id;
}

sub send_response ($self, $request_id, $payload = {}) {
    $self->_write({response => {%$payload, request_id => $request_id}});
    return;
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

Frame, compress, and write one message hashref. Drops the connection on a write
failure (a vanished peer).

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
    my $sent = eval { write_frame($self->{+FH}, compress_blob(encode_json($message)), 'h2-conn'); 1 };
    $self->close unless $sent;
    return;
}

sub _classify ($self, $payload, $rec) {
    my $is_identity   = ref($payload->{identity}) eq 'HASH';
    my $is_request    = ref($payload->{request})  eq 'HASH';
    my $is_response   = ref($payload->{response}) eq 'HASH';
    my $is_transition = ref($payload->{facet_data}) eq 'HASH' || exists $payload->{transition};

    # --- pending: the first frame decides the connection's kind ---------------
    unless ($self->{+READY}) {
        if ($is_identity) {
            $self->{+READY}    = 1;
            $self->{+BAD}      = 0;
            $self->{+IDENTITY} = $payload->{identity}{name};
            $self->send_identity;    # accepter replies; dialer already sent (no-op)
            return {kind => 'identity', name => $self->{+IDENTITY}};
        }

        # A transition as the first frame marks a one-way collector reporter: it
        # never sends identity and only streams transitions.
        if ($is_transition) {
            $self->{+READY}    = 1;
            $self->{+REPORTER} = 1;
            $self->{+BAD}      = 0;
            return {kind => 'transition', payload => $payload, frame => $rec->{frame}};
        }

        # A request / response / unknown frame before establishment is bad.
        $self->close;
        return undef;
    }

    # --- reporter: transitions only -------------------------------------------
    if ($self->{+REPORTER}) {
        if ($is_transition) {
            $self->{+BAD} = 0;
            return {kind => 'transition', payload => $payload, frame => $rec->{frame}};
        }
        $self->_bad_frame;
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
