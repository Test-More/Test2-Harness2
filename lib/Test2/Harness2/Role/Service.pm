package Test2::Harness2::Role::Service;
use v5.38;

our $VERSION = '2.000000';

use POSIX qw/WNOHANG/;
use IO::Select ();
use Time::HiRes qw/sleep/;
use File::Spec ();
use File::Path qw/make_path/;

use Test2::Collector::Util::Socket qw/open_unix_listen connect_unix write_frame/;
use Test2::Collector::Util::Zstd qw/compress_blob/;
use Test2::Collector::Util::Zstd::FrameBuffer();
use Test2::Harness2::Util::JSON qw/encode_json decode_json/;

use Role::Tiny;

requires qw/workdir name/;

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Role::Service - Common socket-service behavior: a listening
unix socket, one bidirectional connection set, a symmetric request/response
loop, and child reaping.

=head1 DESCRIPTION

A role for the harness's long-lived services. It owns a listening unix socket
(C<< $workdir/[$run_ord/]$name.socket >>) and provides the building blocks for a
service loop: it can accept new client connections, B<connect out> to peer
services, read framed requests off any connection and dispatch them to
C<request_handler_E<lt>typeE<gt>>, give the consumer a chance to do its own work
(C<service_tick>), and reap exited children.

Requests and responses are JSON, each compressed into one self-contained zstd
frame and written with the same framing the transition channel uses, so a
L<Test2::Collector::Util::Zstd::FrameBuffer> splits them on the read side. The
wire utilities are reused directly from L<Test2-Collector|Test2::Collector>
(L<Test2::Collector::Util::Socket> and L<Test2::Collector::Util::Zstd>); this
role does not carry its own socket or zstd copies.

=head2 One bidirectional connection set (ARCHITECTURE.md §5.2)

Every connection -- whether this service B<accepted> it or B<dialed> it via
C<service_connect_peer> -- lands in B<one> connection set and the service reads
framed messages off all of them. A dialed (outbound) connection is therefore not
write-only: once open, B<either end may send requests>, so a peer the runner
connects out to (e.g. a preload stage) can send requests back over that same
connection rather than opening a second one in the opposite direction. This is
the symmetric, reuse-never-duplicate model: there is never a second channel
between the same two services.

=head2 Peer identity handshake

A unix C<accept>ed stream carries no service identity, so to reuse a connection
"by peer" each side must learn who is on the other end. A service connection
exchanges a B<handshake frame> (C<< {handshake =E<gt> {identity =E<gt> $name}} >>)
immediately on open -- the dialer sends its identity, the accepter replies with
its own -- B<before> the connection is treated as a registered peer. The identity
keys C<service_connect_peer>'s reuse lookup, and resolves the
B<simultaneous-connect race> (both sides dial at once): both ends deterministically
keep the connection whose initiator has the lexically-smaller identity and drop
the duplicate, so they converge on the same single channel.

A connection that never handshakes (a one-way collector reporter, or a plain
request/reply client) still works exactly as before -- the handshake frame is one
more discriminated frame kind, not a mandatory preamble.

=head2 Frame kinds

C<_service_conn> reads each connection and dispatches by frame kind:

=over 4

=item * B<Handshake> -- C<< {handshake =E<gt> {...}} >>: register the peer
identity (replying with our own handshake if we have not yet), no other effect.

=item * B<Transition> -- a C<facet_data> hashref carrying C<harness_collector> /
C<harness_state_transition> / C<harness_final_state> /
C<harness_collector_finalized>: handed to the consumer's optional
C<service_transition($payload, $frame, $conn)> hook, no reply.

=item * B<Request> -- everything else (C<< {request =E<gt> $type, ...} >>):
dispatched to C<request_handler_$type($payload, $conn)>, whose return value (a
hashref) is sent back as the response. A handler may return C<undef> to send
B<no> response, for one-way requests.

=back

A connection can also become a B<subscriber>: a request handler calls
L</add_subscriber> on the connection, and from then on the service pushes
forwarded frames to it asynchronously with L</forward_frame>. A subscriber whose
write fails (it vanished) is dropped, mirroring the recorder-socket
broken-connection handling.

=head2 Required / optional consumer methods

C<workdir> and C<name> are required. Optional: C<service_identity> (the name this
service announces in its handshake; defaults to C<service_name>), C<run_ord> (a
per-run numeric subdir), C<service_on_start> (called once after the socket
binds), C<service_tick> (called each loop iteration), C<service_on_stop> (called
once after the loop exits, before the socket is closed),
C<service_on_reap($pid, $status)>, and
C<service_transition($payload, $frame, $conn)> (called for each transition frame
received on a connection).

A consumer that already manages its own child processes (for example via
L<Test2::Harness2::IPC>) should override C<reap_children> to a no-op so the two
reaping paths do not race for the same C<waitpid>.

=head1 PUBLIC METHODS

=over 4

=item $name = $self->service_name

The base name used for the listen socket file. Defaults to C<name>; a consumer
that binds different sockets at different times (e.g. the runner, which is
C<runner> in its root process but C<preload-E<lt>stageE<gt>> in a forked stage
child) overrides this to vary the socket without changing its identity.

=item $id = $self->service_identity

The identity this service announces to peers in its handshake (and the key peers
reuse its connection by). Defaults to C<service_name>.

=item $path = $self->service_socket_path

The listen socket path: C<< $workdir/$name.socket >>, or
C<< $workdir/runs/$run_ord/$name.socket >> when the consumer provides a
C<run_ord> (a per-run subdir, so two runs sharing one persistent runner cannot
collide on a stage socket -- chunk 6.1-2).

=item $self->start_service

Open (and bind) the listening socket. Creates the socket's directory if needed.

=item $conn = $self->service_connect_peer($identity, $path)

Return a connection to the peer service named C<$identity>, B<reusing> an existing
one if this service already has a connection to that peer, otherwise dialing
C<$path>, adding the connection to the one shared set (so replies/requests from
the peer are read off it like any other), and sending our handshake. Returns the
connection filehandle, or C<undef> if the dial failed.

=item $conn = $self->service_peer_conn($identity)

The existing connection to peer C<$identity>, or C<undef>.

=item $bool = $self->service_send($identity, $message)

Frame, compress, and write one message (a hashref) to the peer named C<$identity>
over the shared connection. Returns true if written, false if there is no live
connection to that peer.

=item $self->run

Run the service loop until stopped: reap children, service socket I/O, and call
C<service_tick>, sleeping briefly between iterations.

=item $self->service_io

Accept pending connections, read framed messages off ready connections, dispatch
each, and write the response frame back on the same connection. Exposed so a
consumer with its own loop can poll the socket without delegating its whole loop
to C<run>.

=item $self->stop_service

Ask the loop to exit after the current iteration.

=item $self->close_service

Close the listening socket and all connections, and unlink the socket path. Safe
to call more than once; a consumer driving its own loop should call this when it
tears the service down.

=item $self->reset_service

Close and drop the listening socket and all connections B<without> unlinking the
socket path, then clear the service state so a subsequent C<start_service> binds
fresh. Used by a forked child that inherited its parent's listen descriptor and
must drop it (without removing the parent's socket file) before binding its own.

=item $bool = $self->service_stopped

True once C<stop_service> has been requested.

=item $self->reap_children

Reap every exited child (C<WNOHANG>), calling C<service_on_reap($pid, $status)>
for each when the consumer provides it.

=item $resp = $self->handle_request($payload, $conn)

Dispatch one decoded request to C<request_handler_$type>, returning its response
hashref (or an error hashref for a missing type / unknown handler).

=item $resp = $self->request_handler_stop

Built-in handler: stop the loop. Returns C<< {ok =E<gt> 1, stopping =E<gt> 1} >>.

=item add_subscriber

=item $self->add_subscriber($conn)

=item $self->add_subscriber($conn, $run_id)

Register an accepted connection as a subscriber: it stays open and the service
pushes forwarded frames to it (via L</forward_frame>) as state mutates, rather
than serving it a single request/reply. A request handler calls this on its
C<$conn> after sending the snapshot reply. With a C<$run_id> the subscriber is
B<run-scoped>: L</forward_frame> sends it only that run's frames (plus global /
run-less frames). With no C<$run_id> the subscriber is B<global> and receives
every frame (what C<watch> uses).

=item forward_frame

=item $self->forward_frame($frame)

=item $self->forward_frame($frame, $run_id)

Write one already-compressed frame to subscriber connections. C<$run_id> is the
frame's run association (C<undef> = a global / run-less frame, which goes to
B<every> subscriber). A run-associated frame goes to the global subscribers plus
the subscribers scoped to that run. A subscriber whose write fails (it vanished)
is closed and dropped, so a gone subscriber does not cause a write storm or block
the others.

=back

=cut

sub service_name ($self) { return $self->name }

sub service_identity ($self) { return $self->service_name }

sub service_socket_path ($self) {
    my $dir = $self->workdir;

    # Chunk 6.1-2: a run-scoped service nests its socket under a per-run subdir
    # (LOCKED: runs/<run_id>/<name>.socket) so two runs sharing one persistent
    # runner cannot collide on a preload-<stage>.socket. The global runner.socket
    # and the global (shared, runner-lifetime) preload-<stage>.socket stay flat in
    # the workdir -- a consumer signals run-scoping by providing run_ord (its
    # run_id). No consumer triggers a run-scoped stage yet (run-scoped preload
    # stages are a future feature; see Runner::run_ord), so this is the naming
    # foundation, exercised by t/AI/unit/Role_Service.t.
    $dir = File::Spec->catdir($dir, 'runs', $self->run_ord)
        if $self->can('run_ord') && defined $self->run_ord;

    return File::Spec->catfile($dir, $self->service_name . '.socket');
}

sub start_service ($self) {
    my $path = $self->service_socket_path;

    my ($vol, $dir) = File::Spec->splitpath($path);
    my $sockdir = File::Spec->catpath($vol, $dir, '');
    make_path($sockdir) if length $sockdir && !-d $sockdir;

    my $listen = open_unix_listen($path);
    $listen->blocking(0);

    $self->{service_listen}  = $listen;
    $self->{service_select}  = IO::Select->new($listen);
    $self->{service_conns}   = {};
    $self->{service_peers}   = {};
    $self->{service_subs}    = {};
    $self->{service_stopped} = 0;

    return;
}

sub run ($self) {
    $self->start_service unless $self->{service_listen};
    $self->service_on_start if $self->can('service_on_start');

    until ($self->{service_stopped}) {
        $self->reap_children;
        $self->service_io;
        $self->service_tick if $self->can('service_tick');
        sleep 0.01;
    }

    $self->service_on_stop if $self->can('service_on_stop');
    $self->close_service;
    return;
}

sub stop_service ($self) {
    $self->{service_stopped} = 1;
    return;
}

sub service_stopped ($self) {
    return $self->{service_stopped} ? 1 : 0;
}

sub reap_children ($self) {
    my $can = $self->can('service_on_reap');
    while ((my $pid = waitpid(-1, WNOHANG)) > 0) {
        my $status = $?;
        $self->$can($pid, $status) if $can;
    }
    return;
}

sub service_connect_peer ($self, $identity, $path) {
    # Reuse, never duplicate (ARCH 5.2): if a connection to this peer already
    # exists -- whether we dialed it or it dialed us and handshaked -- hand it
    # back rather than opening a second channel.
    if (my $existing = $self->{service_peers}{$identity}) {
        return $existing;
    }

    my $conn;
    return undef unless eval { $conn = connect_unix($path); 1 } && $conn;
    $conn->blocking(0);

    # The dialed connection joins the one shared set so the peer's requests /
    # replies are read off it like any accepted connection (symmetric channel).
    $self->{service_select}->add($conn);
    $self->{service_conns}{$conn} = {
        fh             => $conn,
        fb             => Test2::Collector::Util::Zstd::FrameBuffer->new,
        outbound       => 1,
        identity       => $identity,
        handshake_sent => 0,
    };

    # We know who we dialed, so register the peer now; the handshake reply only
    # confirms it. (A simultaneous reverse-dial is resolved when its handshake
    # arrives -- see _handle_handshake.)
    $self->{service_peers}{$identity} = $conn;

    $self->_send_handshake($conn);

    return $conn;
}

sub service_peer_conn ($self, $identity) {
    return $self->{service_peers}{$identity};
}

sub service_send ($self, $identity, $message) {
    my $conn = $self->{service_peers}{$identity} or return 0;
    return eval { write_frame($conn, compress_blob(encode_json($message)), 'peer'); 1 } ? 1 : 0;
}

sub handle_request ($self, $payload, $conn) {
    $payload = {request => $payload} unless ref($payload) eq 'HASH';

    my $type = $payload->{request};
    return {ok => 0, error => 'missing request type'} unless defined $type;

    return $self->request_handler_stop($payload, $conn) if $type eq 'stop';

    my $handler = "request_handler_$type";
    return {ok => 0, error => "unknown request '$type'"} unless $self->can($handler);

    return $self->$handler($payload, $conn);
}

sub request_handler_stop ($self, $payload = undef, $conn = undef) {
    $self->stop_service;
    return {ok => 1, stopping => 1};
}

sub add_subscriber ($self, $conn, $run_id = undef) {
    $self->{service_subs}{$conn} = {conn => $conn, run_id => $run_id};
    return;
}

sub forward_frame ($self, $frame, $run_id = undef) {
    my $subs = $self->{service_subs} or return;
    return unless %$subs;

    for my $key (keys %$subs) {
        my $sub  = $subs->{$key};
        my $conn = $sub->{conn};

        # Per-run routing (chunk 6.1): a global subscriber (no run_id) gets every
        # frame; a run-scoped subscriber gets the global / run-less frames plus the
        # frames of its own run. A run-associated frame to a different run is
        # skipped.
        next if defined $sub->{run_id}
            && defined $run_id
            && $sub->{run_id} ne $run_id;

        # A vanished subscriber must not be retried on every later frame (a warn
        # storm / fd leak); drop and close it, mirroring the recorder socket's
        # broken-connection handling.
        next if eval { write_frame($conn, $frame, 'subscriber'); 1 };

        delete $self->{service_subs}{$key};
        $self->_drop_conn($conn);
    }

    return;
}

=head1 PRIVATE METHODS

=over 4

=item $self->service_io

The socket-servicing primitive used by both C<run> and consumer-driven loops; see
the public description above.

=item $self->close_service

The teardown primitive; see the public description above.

=item $self->_service_conn($fh)

Read one ready connection and dispatch each complete frame it carries by kind
(handshake / transition / request).

=item $self->_handle_handshake($fh, $payload)

Register the peer identity a handshake frame carries, reply with our own handshake
if we have not yet, and resolve a simultaneous-connect duplicate deterministically.

=item $self->_send_handshake($fh)

Write this service's handshake frame on a connection (once).

=item $self->_drop_conn($fh)

Remove a connection from the select set, the connection map, the peer registry,
and the subscriber set, then close it.

=item $bool = $self->_is_transition_frame($payload)

True when a decoded payload is a collector transition frame (a C<facet_data>
hashref carrying C<harness_collector>, C<harness_state_transition>,
C<harness_final_state>, or C<harness_collector_finalized>) rather than a request.

=item $bool = $self->_is_handshake_frame($payload)

True when a decoded payload is a peer-identity handshake frame.

=back

=cut

sub service_io ($self) {
    my $sel    = $self->{service_select} or return;
    my $listen = $self->{service_listen};

    while (my $conn = $listen->accept) {
        $conn->blocking(0);
        $sel->add($conn);
        $self->{service_conns}{$conn} = {
            fh             => $conn,
            fb             => Test2::Collector::Util::Zstd::FrameBuffer->new,
            outbound       => 0,
            identity       => undef,
            handshake_sent => 0,
        };
    }

    for my $fh ($sel->can_read(0)) {
        next if $fh == $listen;
        $self->_service_conn($fh);
    }

    return;
}

sub _service_conn ($self, $fh) {
    my $meta = $self->{service_conns}{$fh} or return;
    my $fb   = $meta->{fb};

    my $buf = '';
    my $n   = sysread($fh, $buf, 65536);
    return unless defined $n;

    if ($n == 0) {
        $self->_drop_conn($fh);
        return;
    }

    $fb->push_bytes($buf);
    for my $rec ($fb->drain) {
        my $payload;
        my $ok = eval { $payload = decode_json($rec->{payload}); 1 };

        unless ($ok) {
            my $sent = eval { write_frame($fh, compress_blob(encode_json({ok => 0, error => "undecodable request"}))); 1 };
            warn "service: failed to write response: $@\n" unless $sent;
            next;
        }

        # A peer-identity handshake (ARCH 5.2): register who is on the other end
        # so the connection can be reused by peer, then keep reading -- it carries
        # no request.
        if ($self->_is_handshake_frame($payload)) {
            $self->_handle_handshake($fh, $payload);
            next;
        }

        # Two further kinds share every connection (one connection per peer, ARCH
        # 5.2): transition frames (Test2 event/facet structures a collector's
        # reporter streams, carrying C<harness_collector> /
        # C<harness_state_transition> / etc) and request frames
        # (C<< {request =E<gt> $type, ...} >> -- run/task submission and stage
        # outcome reports). Transitions are one-way and fold into the consumer's
        # state, never producing a reply; requests dispatch to
        # C<request_handler_E<lt>typeE<gt>>.
        if ($self->_is_transition_frame($payload)) {
            $self->service_transition($payload, $rec->{frame}, $fh)
                if $self->can('service_transition');
            next;
        }

        my $resp = $self->handle_request($payload, $fh);

        # A handler may return undef to send no response (one-way requests, e.g.
        # streamed reports), so the sender's socket does not accumulate unread
        # replies.
        next unless defined $resp;

        my $sent = eval { write_frame($fh, compress_blob(encode_json($resp))); 1 };
        warn "service: failed to write response: $@\n" unless $sent;
    }

    return;
}

sub _is_handshake_frame ($self, $payload) {
    return 0 unless ref($payload) eq 'HASH';
    return ref($payload->{handshake}) eq 'HASH' ? 1 : 0;
}

sub _send_handshake ($self, $fh) {
    my $meta = $self->{service_conns}{$fh} or return;
    return if $meta->{handshake_sent};
    $meta->{handshake_sent} = 1;
    eval { write_frame($fh, compress_blob(encode_json({handshake => {identity => $self->service_identity}})), 'handshake'); 1 };
    return;
}

sub _handle_handshake ($self, $fh, $payload) {
    my $meta = $self->{service_conns}{$fh} or return;
    my $peer = $payload->{handshake}{identity};
    return unless defined $peer;

    # The accepter learns the dialer's identity here and replies with its own so
    # the dialer can register us too. (An outbound connection already sent its
    # handshake in service_connect_peer.)
    $self->_send_handshake($fh) unless $meta->{handshake_sent};

    my $existing = $self->{service_peers}{$peer};

    # Simultaneous connect: both sides dialed each other, so each holds two
    # connections to the same peer. Keep the one whose initiator has the
    # smaller identity -- both ends compute this identically and so converge on
    # the same single channel -- and drop the other.
    if ($existing && $existing != $fh) {
        if ($self->_keep_this_conn($meta, $peer)) {
            $self->_drop_conn($existing);
        }
        else {
            $self->_drop_conn($fh);
            return;
        }
    }

    $meta->{identity} = $peer;
    $self->{service_peers}{$peer} = $fh;

    return;
}

sub _keep_this_conn ($self, $meta, $peer) {
    my $me = $self->service_identity;

    # The connection's initiator is us when we dialed out, else the peer. Keep the
    # connection whose initiator sorts first; the other end keeps the same one.
    my $initiator = $meta->{outbound} ? $me   : $peer;
    my $other     = $meta->{outbound} ? $peer : $me;

    return $initiator lt $other ? 1 : 0;
}

sub _drop_conn ($self, $fh) {
    if (my $meta = delete $self->{service_conns}{$fh}) {
        my $id = $meta->{identity};
        delete $self->{service_peers}{$id}
            if defined $id && ($self->{service_peers}{$id} // 0) == $fh;
    }
    $self->{service_select}->remove($fh) if $self->{service_select};
    delete $self->{service_subs}{$fh};
    eval { close($fh); 1 };
    return;
}

sub _is_transition_frame ($self, $payload) {
    return 0 unless ref($payload) eq 'HASH';
    my $fd = $payload->{facet_data};
    return 0 unless ref($fd) eq 'HASH';
    return 1
        if $fd->{harness_collector}
        || $fd->{harness_state_transition}
        || $fd->{harness_final_state}
        || $fd->{harness_collector_finalized};
    return 0;
}

sub reset_service ($self) {
    if (my $sel = $self->{service_select}) {
        for my $fh ($sel->handles) {
            $sel->remove($fh);
            close($fh);
        }
    }
    delete $self->{service_listen};
    delete $self->{service_select};
    $self->{service_conns}   = {};
    $self->{service_peers}   = {};
    $self->{service_subs}    = {};
    $self->{service_stopped} = 0;
    return;
}

sub close_service ($self) {
    if (my $sel = $self->{service_select}) {
        for my $fh ($sel->handles) {
            $sel->remove($fh);
            close($fh);
        }
    }
    $self->{service_conns} = {};
    $self->{service_peers} = {};
    $self->{service_subs}  = {};

    if (delete $self->{service_listen}) {
        my $path = $self->service_socket_path;
        unlink $path if -e $path;
    }

    return;
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
