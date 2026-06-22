package Test2::Harness2::Runner::Client;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use File::Spec();
use Time::HiRes qw/sleep time/;

use Test2::Collector::Util::Socket qw/connect_unix/;

use Test2::Harness2::Role::Service::Connection();

use Test2::Harness2::Util::HashBase qw{
    <workdir
    <liveness_check
    +identity
    +socket_path
    +connection
    +runner_gone
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::Client - Thin client that submits a run and its tasks
to a runner over its unix socket.

=head1 DESCRIPTION

A command (C<yath test> / C<run> / C<spawn> / C<status> / ...) is a thin client of
the runner service: it connects to the runner's C<runner.socket> and exchanges the
mandatory identity handshake (ARCHITECTURE.md §5.2), then submits run/task
requests and issues queries. The transport is a
L<Test2::Harness2::Role::Service::Connection>, which owns the framing, the identity
exchange, and request/response correlation, so this class only maps the command's
API onto C<send_request>.

Most submissions are B<one-way>: the runner's handler returns no response and the
client moves on. A few are B<two-way> (acknowledged): they send a request and wait
for the response whose C<request_id> matches -- the status/abort/reload queries.
Because the protocol makes no ordering assumption, the wait drains the connection
and matches the reply by id.

The runner is a separate process spawned just before submission, so it may not be
listening yet; the connect retries with a short backoff. An optional
C<liveness_check> coderef lets the caller tell the client the runner has died
before it ever accepted, so the client stops trying and submission becomes a no-op
rather than hanging.

=head1 PUBLIC METHODS

=over 4

=item $path = $client->socket_path

The runner socket path (C<< $workdir/runner.socket >>).

=item $id = $client->identity

The identity this client announces (C<command-E<lt>pidE<gt>> by default).

=item $bool = $client->runner_gone

True once the runner was observed to have exited before the client could connect.

=item $coderef = $client->liveness_check

The optional caller-supplied check that returns true while the runner is alive.

=item $client->queue_run($run)

Submit the run definition.

=item $client->queue_task($task)

Submit one task.


=item $client->stop_run($run_id)

Signal that no more tasks will be queued for the given run.

=item $client->end_queue

Signal that no more runs/work will be submitted.

=item $client->stop

Ask the runner service to shut down gracefully (used by C<yath stop>).

=item $client->halt_run($run_id)

Ask the runner to halt the run (used on a caught signal).

=item $hash = $client->reload_state

Query the runner's canonical reload state. Two-way: returns the reload-state hash
(possibly empty), or C<undef> if the runner could not be reached.

=item $hash = $client->status

Query the runner's live scheduling status. Two-way: returns the status hash, or
C<undef> if the runner could not be reached.

=item $running = $client->truncate

Ask the runner to truncate its queue (abort pending work) and return the list of
still-running jobs (with pids). Two-way.

=item $resources = $client->resources

Query the runner's live resource status. Two-way: returns the rendered resource
list, or C<undef> if the runner could not be reached.

=back

=cut

sub socket_path ($self) {
    return $self->{+SOCKET_PATH} //= File::Spec->catfile($self->{+WORKDIR}, 'runner.socket');
}

sub identity ($self) {
    return $self->{+IDENTITY} //= "command-$$";
}

sub queue_run    ($self, $run)     { $self->_send('queue_run', run => $run);     return }
sub queue_task   ($self, $task)    { $self->_send('queue_task', task => $task);  return }
sub stop_run     ($self, $run_id)  { $self->_send('stop_run', run_id => $run_id); return }
sub end_queue    ($self)           { $self->_send('end_queue');                  return }
sub stop         ($self)           { $self->_send('stop');                       return }
sub halt_run     ($self, $run_id)  { $self->_send('halt_run', run_id => $run_id); return }

sub reload_state ($self) {
    my $reply = $self->_request('reload_state') or return undef;
    return $reply->{reload_state} // {};
}

sub status ($self) {
    my $reply = $self->_request('status') or return undef;
    return $reply->{status};
}

sub truncate ($self) {
    my $reply = $self->_request('truncate') or return undef;
    return $reply->{running} // [];
}

sub resources ($self) {
    my $reply = $self->_request('resources') or return undef;
    return $reply->{resources} // [];
}

=head1 PRIVATE METHODS

=over 4

=item $conn = $client->connection

The (lazily opened) L<Test2::Harness2::Role::Service::Connection> to the runner,
or C<undef> if the runner was observed to have exited before it accepted. Retries
the connect with a short backoff, then exchanges identity before returning.

=item $bool = $client->_runner_alive

Run the C<liveness_check> coderef (true when absent).

=item $client->_send($command, %args)

Send one one-way request (a no-op once the runner is gone).

=item $reply = $client->_request($command, %args)

Send one request and wait for the response whose C<request_id> matches, draining
the connection meanwhile. Returns the response payload, or C<undef> if the runner
could not be reached. Croaks on a closed connection or timeout.

=back

=cut

# How long to wait for the runner to bind/accept (and to reply) before giving up
# when we cannot otherwise tell the runner is gone.
sub CONNECT_TIMEOUT { 30 }

sub runner_gone ($self) { return $self->{+RUNNER_GONE} ? 1 : 0 }

sub _runner_alive ($self) {
    my $check = $self->{+LIVENESS_CHECK} or return 1;    # no check: assume alive
    return $self->$check ? 1 : 0;
}

sub connection ($self) {
    my $conn = $self->{+CONNECTION};
    return $conn if $conn && !$conn->closed;

    my $path  = $self->socket_path;
    my $start = time;

    my $fh;
    while (1) {
        if (-S $path) {
            last if eval { $fh = connect_unix($path); 1 } && $fh;
        }

        # If the runner died before it ever started accepting there is nothing to
        # connect to; stop trying so submission becomes a no-op.
        unless ($self->_runner_alive) {
            $self->{+RUNNER_GONE} = 1;
            return undef;
        }

        croak "Timed out waiting for runner socket '$path' to accept connections"
            if (time - $start) > $self->CONNECT_TIMEOUT;

        sleep 0.05;
    }

    $fh->blocking(0);
    $conn = Test2::Harness2::Role::Service::Connection->new(
        fh          => $fh,
        outbound    => 1,
        my_identity => $self->identity,
    );

    # The Connection has already sent our identity (the runner needs it before any
    # request). We do NOT block waiting for the runner's identity in return: the
    # client matches responses by request_id, never by peer identity, so it needs
    # nothing back to proceed. (Blocking here would also deadlock a single-threaded
    # caller that pumps the runner only after this returns.) Two-way _request drains
    # the reply -- and the runner's identity -- when it waits for its response.
    return $self->{+CONNECTION} = $conn;
}

sub _send ($self, $command, %args) {
    my $conn = $self->connection or return;
    $conn->send_request($command, %args);
    return;
}

sub _request ($self, $command, %args) {
    my $conn = $self->connection or return undef;
    my $id   = $conn->send_request($command, %args);

    my $start = time;
    while (1) {
        for my $event ($conn->drain) {
            next unless $event->{kind} eq 'response';
            return $event->{payload} if $event->{request_id} eq $id;
        }

        croak "runner closed the connection before sending a reply" if $conn->closed;
        croak "Timed out waiting for the runner's reply"
            if (time - $start) > $self->CONNECT_TIMEOUT;

        sleep 0.01;
    }
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
