package Test2::Harness2::Role::Service;
use v5.38;

our $VERSION = '2.000000';

use POSIX qw/WNOHANG/;
use IO::Select ();
use Time::HiRes qw/sleep/;
use File::Spec ();
use File::Path qw/make_path/;

use Test2::Collector::Util::Socket qw/open_unix_listen write_frame/;
use Test2::Collector::Util::Zstd qw/compress_blob/;
use Test2::Collector::Util::Zstd::FrameBuffer();
use Test2::Harness2::Util::JSON qw/encode_json decode_json/;

use Role::Tiny;

requires qw/workdir name/;

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Role::Service - Common socket-service behavior: a listening
unix socket, a request/response loop, and child reaping.

=head1 DESCRIPTION

A role for the harness's long-lived services. It owns a listening unix socket
(C<< $workdir/[$run_ord/]$name.socket >>) and provides the building blocks for a
service loop: it can accept new client connections, read framed requests and
dispatch them to C<request_handler_E<lt>typeE<gt>>, give the consumer a chance to
do its own work (C<service_tick>), and reap exited children.

Requests and responses are JSON, each compressed into one self-contained zstd
frame and written with the same framing the transition channel uses, so a
L<Test2::Collector::Util::Zstd::FrameBuffer> splits them on the read side. The
wire utilities are reused directly from L<Test2-Collector|Test2::Collector>
(L<Test2::Collector::Util::Socket> and L<Test2::Collector::Util::Zstd>); this
role does not carry its own socket or zstd copies.

A request is C<< {request =E<gt> $type, ...} >>; it dispatches to
C<request_handler_$type($payload, $conn)>, whose return value (a hashref) is sent
back as the response. A handler may return C<undef> to send B<no> response, for
one-way requests (e.g. streamed reports) whose sender does not read replies. The
built-in C<request_handler_stop> ends the loop.

The same socket also carries B<transition frames>: the Test2 event/facet
structures a collector's reporter streams (carrying C<harness_collector>,
C<harness_state_transition>, C<harness_final_state>, or
C<harness_collector_finalized>). A frame whose decoded payload carries a
C<facet_data> with any of those facets is recognized as a transition, handed to
the consumer's optional C<service_transition($payload, $frame, $conn)> hook, and
produces no reply. Everything else is treated as a request. One connection per
peer (a collector's connection streams many transition frames) means the two
kinds never interleave on a single stream.

=head2 Required / optional consumer methods

C<workdir> and C<name> are required. Optional: C<run_ord> (a per-run numeric
subdir), C<service_on_start> (called once after the socket binds),
C<service_tick> (called each loop iteration), C<service_on_stop> (called once
after the loop exits, before the socket is closed),
C<service_on_reap($pid, $status)>, and
C<service_transition($payload, $frame, $conn)> (called for each transition frame
received on the socket).

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

=item $path = $self->service_socket_path

The listen socket path: C<< $workdir/$name.socket >>, or
C<< $workdir/$run_ord/$name.socket >> when the consumer provides a C<run_ord>.

=item $self->start_service

Open (and bind) the listening socket. Creates the socket's directory if needed.

=item $self->run

Run the service loop until stopped: reap children, service socket I/O, and call
C<service_tick>, sleeping briefly between iterations.

=item $self->service_io

Accept pending connections, read framed requests off ready connections, dispatch
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

=back

=cut

sub service_name ($self) { return $self->name }

sub service_socket_path ($self) {
    my $dir = $self->workdir;
    $dir = File::Spec->catdir($dir, $self->run_ord)
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

=head1 PRIVATE METHODS

=over 4

=item $self->service_io

The socket-servicing primitive used by both C<run> and consumer-driven loops; see
the public description above.

=item $self->close_service

The teardown primitive; see the public description above.

=item $bool = $self->_is_transition_frame($payload)

True when a decoded payload is a collector transition frame (a C<facet_data>
hashref carrying C<harness_collector>, C<harness_state_transition>,
C<harness_final_state>, or C<harness_collector_finalized>) rather than a request.

=back

=cut

sub service_io ($self) {
    my $sel    = $self->{service_select} or return;
    my $listen = $self->{service_listen};

    while (my $conn = $listen->accept) {
        $conn->blocking(0);
        $sel->add($conn);
        $self->{service_conns}{$conn} = Test2::Collector::Util::Zstd::FrameBuffer->new;
    }

    for my $fh ($sel->can_read(0)) {
        next if $fh == $listen;
        $self->_service_conn($fh);
    }

    return;
}

sub _service_conn ($self, $fh) {
    my $fb = $self->{service_conns}{$fh} or return;

    my $buf = '';
    my $n   = sysread($fh, $buf, 65536);
    return unless defined $n;

    if ($n == 0) {
        $self->{service_select}->remove($fh);
        delete $self->{service_conns}{$fh};
        close($fh);
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

        # Two kinds of frame share this socket (one connection per peer, ARCH
        # 5.2): request frames (C<< {request =E<gt> $type, ...} >> -- run/task
        # submission and stage outcome reports) and transition frames (Test2
        # event/facet structures a collector's reporter streams, carrying
        # C<harness_collector> / C<harness_state_transition> / etc). Transitions
        # are one-way and fold into the consumer's state, never producing a
        # reply; requests dispatch to C<request_handler_E<lt>typeE<gt>>.
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
