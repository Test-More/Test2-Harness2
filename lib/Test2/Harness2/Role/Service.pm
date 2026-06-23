package Test2::Harness2::Role::Service;
use v5.38;

our $VERSION = '2.000000';

use IO::Select ();
use File::Spec ();
use File::Path qw/make_path/;

use Test2::Collector::Util::Socket qw/open_unix_listen connect_unix write_frame/;
use Test2::Harness2::Util::IPC qw/set_cloexec/;

use Test2::Harness2::Role::Service::Connection();

use Role::Tiny;

requires qw/workdir name/;

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Role::Service - Common socket-service behavior: a listening
unix socket, one bidirectional connection set, and an identified
request/response loop.

=head1 DESCRIPTION

A role for the harness's long-lived services. It owns a listening unix socket
(C<< $workdir/[$run_id/]$name.socket >>) and the socket-servicing primitive
(C<service_io>): accept new connections, B<connect out> to peer services, and
read framed messages off every connection and dispatch each by kind. The
consumer drives its own loop, calling C<service_io> (and C<service_tick>) each
iteration.

Each connection is a L<Test2::Harness2::Role::Service::Connection>, which owns the
wire protocol (ARCHITECTURE.md §5.2): an identity exchange on open, framed
C<{request =E<gt> {request_id, command, ...}}> / C<{response =E<gt> {request_id,
...}}> messages matched by id (B<no ordering assumption>), and the bad-frame
policy. A one-way collector reporter (which streams C<transition> / C<facet_data>
frames and never identifies) is recognized as a reporter and accepted too. This
role drives those connections: it dispatches each request to
C<request_handler_E<lt>commandE<gt>> and sends the handler's return value back as
the response (a handler returning C<undef> sends B<no> response, for one-way
requests), hands transitions to the consumer's optional
C<service_transition($payload, $frame, $conn)> hook, and routes a response to the
optional C<service_on_response($conn, $event)> hook.

=head2 Required / optional consumer methods

C<workdir> and C<name> are required. Optional: C<service_identity> (the name this
service announces; defaults to C<service_name>), C<run_id> (the run's run_id
(UUID) subdir), C<service_tick>, C<service_transition($payload, $frame, $conn)>,
C<service_on_response($conn, $event)>, C<service_identified($conn, $payload)>
(called when a peer announces its full identity, for connection-to-job mapping),
and C<service_conn_closed($conn)> (called when a peer connection is dropped, for
connection-gated cleanup).

=head1 PUBLIC METHODS

=over 4

=item $name = $self->service_name

The base name used for the listen socket file. Defaults to C<name>; a consumer
that binds different sockets at different times (e.g. the runner, which is
C<runner> in its root process but C<preload-E<lt>stageE<gt>> in a forked stage
child) overrides this to vary the socket without changing its identity.

=item $id = $self->service_identity

The identity this service announces to peers (the key peers reach it by). Defaults
to C<service_name>.

=item $path = $self->service_socket_path

The listen socket path: C<< $workdir/$name.socket >>, or
C<< $workdir/runs/$run_id/$name.socket >> when the consumer provides a C<run_id>.

=item $self->start_service

Open (and bind) the listening socket. Creates the socket's directory if needed.

=item $conn = $self->service_connect_peer($identity, $path)

Return a connection to the peer service named C<$identity>, B<reusing> an existing
one if there is one, otherwise dialing C<$path>, adding it to the one shared set,
and announcing our identity. Returns the L<Test2::Harness2::Role::Service::Connection>,
or C<undef> if the dial failed.

=item $conn = $self->service_peer_conn($identity)

The existing connection to peer C<$identity>, or C<undef>.

=item $request_id = $self->service_send($identity, $command, %args)

Send a request to the peer named C<$identity> over the shared connection. Returns
the request_id (truthy) on success, or B<false> if there is no live connection to
that peer B<or the write failed> (the peer vanished mid-write, closing the
connection). The reply, if the handler sends one, arrives later via
C<service_on_response>; one-way requests need no reply.

=item $self->service_io

Accept pending connections, read framed messages off ready connections, and
dispatch each. Exposed so a consumer with its own loop can poll the socket.

=item $self->stop_service

Ask the loop to exit after the current iteration.

=item $self->close_service

Close the listening socket and all connections, and unlink the socket path.

=item $self->close_all_connections

Post-fork close-sweep for a child that does B<not> exec: close every inherited
connection and the listen socket so a forked child holds no dup of any peer
connection or the listen socket. Without it a dead collector's connection would
never EOF (a UNIX socket EOFs only once every holder closes its fd). C<FD_CLOEXEC>
covers exec paths; this covers the no-exec forks (the collector parent and the
preload test launch). It does B<not> unlink the socket path (the parent still
owns it) and leaves service bookkeeping cleared so the child does not act as a
service.

=item $self->reset_service

Close and drop the listening socket and all connections B<without> unlinking the
socket path, then clear the service state so a subsequent C<start_service> binds
fresh.

=item $bool = $self->service_stopped

True once C<stop_service> has been requested.

=item $resp = $self->handle_request($payload, $conn)

Dispatch one request (its inner C<{request_id, command, ...}> hash) to
C<request_handler_$command>, returning its response hashref (or an error hashref
for a missing / unknown command).

=item $resp = $self->request_handler_stop

Built-in handler: stop the loop. Returns C<< {ok =E<gt> 1, stopping =E<gt> 1} >>.

=item $self->add_subscriber($conn, $run_id)

Register a connection as a subscriber: it stays open and the service pushes
forwarded frames to it (via C<forward_frame>) as state mutates. With a C<$run_id>
the subscriber is run-scoped; without one it is global (every frame).

=item $self->forward_frame($frame, $run_id)

Write one already-compressed frame to subscriber connections, routed by C<$run_id>
(C<undef> = global / run-less, goes to every subscriber). A subscriber whose write
fails (it vanished) is dropped.

=back

=cut

sub service_name ($self) { return $self->name }

sub service_identity ($self) { return $self->service_name }

sub service_socket_path ($self) {
    my $dir = $self->workdir;

    # A run-scoped service nests its socket under a per-run subdir
    # (runs/<run_id>/<name>.socket) so two runs sharing one persistent runner
    # cannot collide on a preload-<stage>.socket. A consumer signals run-scoping by
    # providing run_id; no consumer triggers a run-scoped stage yet.
    $dir = File::Spec->catdir($dir, 'runs', $self->run_id)
        if $self->can('run_id') && defined $self->run_id;

    return File::Spec->catfile($dir, $self->service_name . '.socket');
}

sub start_service ($self) {
    my $path = $self->service_socket_path;

    my ($vol, $dir) = File::Spec->splitpath($path);
    my $sockdir = File::Spec->catpath($vol, $dir, '');
    make_path($sockdir) if length $sockdir && !-d $sockdir;

    my $listen = open_unix_listen($path);
    $listen->blocking(0);

    # FD_CLOEXEC so a child that exec's never inherits the listen socket; the
    # no-exec collector-parent fork still close-sweeps it (close_all_connections).
    # See ARCHITECTURE.md §5.4 "FD ownership is a hard prerequisite".
    set_cloexec($listen);

    $self->{service_listen}  = $listen;
    $self->{service_select}  = IO::Select->new($listen);
    $self->{service_conns}   = {};
    $self->{service_peers}   = {};
    $self->{service_subs}    = {};
    $self->{service_stopped} = 0;

    return;
}

sub stop_service ($self) {
    $self->{service_stopped} = 1;
    return;
}

sub service_stopped ($self) {
    return $self->{service_stopped} ? 1 : 0;
}

sub service_connect_peer ($self, $identity, $path) {
    # Reuse, never duplicate: if a connection to this peer already exists -- whether
    # we dialed it or it dialed us -- hand it back rather than opening a second one.
    if (my $existing = $self->{service_peers}{$identity}) {
        return $existing unless $existing->closed;
        $self->_drop_conn($existing);
    }

    my $fh;
    return undef unless eval { $fh = connect_unix($path); 1 } && $fh;
    $fh->blocking(0);
    set_cloexec($fh);

    my $conn = Test2::Harness2::Role::Service::Connection->new(
        fh          => $fh,
        outbound    => 1,
        my_identity => $self->service_identity,
    );

    $self->{service_select}->add($fh);
    $self->{service_conns}{$fh} = $conn;

    # We know who we dialed, so register the peer now; its identity frame confirms.
    $self->{service_peers}{$identity} = $conn;

    return $conn;
}

sub service_peer_conn ($self, $identity) {
    my $conn = $self->{service_peers}{$identity} or return undef;
    return undef if $conn->closed;
    return $conn;
}

sub service_send ($self, $identity, $command, %args) {
    my $conn = $self->service_peer_conn($identity) or return 0;
    return $conn->send_request($command, %args);
}

sub handle_request ($self, $payload, $conn) {
    my $command = $payload->{command};
    return {ok => 0, error => 'missing command'} unless defined $command;

    return $self->request_handler_stop($payload, $conn) if $command eq 'stop';

    my $handler = "request_handler_$command";
    return {ok => 0, error => "invalid command: $command"} unless $self->can($handler);

    return $self->$handler($payload, $conn);
}

sub request_handler_stop ($self, $payload = undef, $conn = undef) {
    $self->stop_service;
    return {ok => 1, stopping => 1};
}

sub add_subscriber ($self, $conn, $run_id = undef, $drain_gate = undef) {
    $self->{service_subs}{$conn} = {conn => $conn, run_id => $run_id, drain_gate => $drain_gate};
    return;
}

sub forward_frame ($self, $frame, $run_id = undef) {
    my $subs = $self->{service_subs} or return;
    return unless %$subs;

    for my $key (keys %$subs) {
        my $sub  = $subs->{$key};
        my $conn = $sub->{conn};

        # Per-run routing: a global subscriber (no run_id) gets every
        # frame; a run-scoped subscriber gets the global / run-less frames plus the
        # frames of its own run.
        next if defined $sub->{run_id}
            && defined $run_id
            && $sub->{run_id} ne $run_id;

        # Push the already-compressed frame verbatim. A vanished subscriber is
        # dropped so it does not cause a write storm.
        next if !$conn->closed && eval { write_frame($conn->fh, $frame, 'subscriber'); 1 };

        delete $self->{service_subs}{$key};
        $self->_drop_conn($conn);
    }

    return;
}

=head1 PRIVATE METHODS

=over 4

=item $self->service_io

The socket-servicing primitive a consumer's own loop calls each iteration.

=item $self->_handle_events($conn, @events)

Act on the classified events a connection's C<drain> produced: register an
identity, dispatch a request and send its response, route a response, or hand a
transition to the consumer.

=item $self->_drop_conn($conn)

Remove a connection from the select set, the connection map, the peer registry,
and the subscriber set, then close it.

=item $self->close_service / $self->reset_service

Teardown primitives; see the public descriptions above.

=back

=cut

sub service_io ($self) {
    my $sel    = $self->{service_select} or return;
    my $listen = $self->{service_listen};

    while (my $fh = $listen->accept) {
        $fh->blocking(0);
        set_cloexec($fh);
        $sel->add($fh);
        $self->{service_conns}{$fh} = Test2::Harness2::Role::Service::Connection->new(
            fh          => $fh,
            outbound    => 0,
            my_identity => $self->service_identity,
        );
    }

    # Read first: always drain whatever is readable before judging a connection
    # silent, so a peer whose identity has arrived (or just arrived this iteration)
    # is never dropped with its data still unread.
    for my $fh ($sel->can_read(0)) {
        next if $fh == $listen;
        my $conn = $self->{service_conns}{$fh} or next;
        my @events = $conn->drain;
        $self->_handle_events($conn, @events) if @events;
        $self->_drop_conn($conn) if $conn->closed;
    }

    # Then drop connections that connected but never identified within the timeout
    # (a genuinely silent / stuck peer -- it had nothing readable above).
    for my $fh (keys %{$self->{service_conns}}) {
        my $conn = $self->{service_conns}{$fh};
        $self->_drop_conn($conn) if $conn->expired;
    }

    return;
}

sub _handle_events ($self, $conn, @events) {
    for my $event (@events) {
        my $kind = $event->{kind};

        if ($kind eq 'identity') {
            $self->{service_peers}{$event->{name}} = $conn;
            # Optional consumer hook: a peer just announced its full identity. The
            # runner uses it to register a test-collector connection (its full
            # identity payload -- job_id / job_try / run_id) so the connection's
            # later EOF maps back to the job (ARCHITECTURE.md §5.4).
            $self->service_identified($conn, $event->{payload})
                if $self->can('service_identified') && $event->{payload};
            next;
        }

        if ($kind eq 'request') {
            my $resp = $self->handle_request($event->{payload}, $conn);
            # A handler returns undef for a one-way request (no reply expected).
            $conn->send_response($event->{request_id}, $resp) if defined $resp;
            next;
        }

        if ($kind eq 'response') {
            $self->service_on_response($conn, $event) if $self->can('service_on_response');
            next;
        }

        if ($kind eq 'transition') {
            $self->service_transition($event->{payload}, $event->{frame}, $conn)
                if $self->can('service_transition');
            next;
        }
    }

    return;
}

sub _drop_conn ($self, $conn) {
    my $fh = $conn->fh;

    delete $self->{service_conns}{$fh};

    my $id = $conn->identity;
    delete $self->{service_peers}{$id}
        if defined $id && ($self->{service_peers}{$id} // 0) == $conn;

    delete $self->{service_subs}{$conn};
    $self->{service_select}->remove($fh) if $self->{service_select};
    $conn->close;

    # Optional consumer hook (ticket #12 / ARCHITECTURE.md §4.2): a closing peer may
    # be the connection that queued a run. The runner uses this to sweep the runs that
    # connection owned -- aborting a still-running run, purging a finished one -- so
    # in-memory run state is bounded by live owner connections.
    $self->service_conn_closed($conn) if $self->can('service_conn_closed');

    return;
}

sub close_all_connections ($self) {
    if (my $conns = $self->{service_conns}) {
        $_->close for values %$conns;
    }

    if (my $listen = $self->{service_listen}) {
        eval { CORE::close($listen); 1 };
    }

    if (my $sel = $self->{service_select}) {
        $sel->remove($_) for $sel->handles;
    }

    delete $self->{service_listen};
    delete $self->{service_select};
    $self->{service_conns} = {};
    $self->{service_peers} = {};
    $self->{service_subs}  = {};

    return;
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
    if (my $conns = $self->{service_conns}) {
        $_->close for values %$conns;
    }
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
