package Test2::Harness2::Runner::Client;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Time::HiRes qw/sleep/;

use Test2::Harness2::Util qw/mono_time/;

use Test2::Harness2::Util::HashBase qw{
    <workdir
    <liveness_check
    +identity
    +socket_path
    +connection
    +runner_gone
};

# The unix-socket connect layer (socket_path, identity, _runner_alive, _connect,
# CONNECT_ATTEMPT_TIMEOUT) is shared with Runner::Subscriber.
use Role::Tiny::With;
with 'Test2::Harness2::Runner::Role::SocketClient';

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

=item $reply = $client->ping

A no-side-effect liveness round-trip (used by C<yath ping>). Two-way: returns the
runner's ack hashref (C<< {ok =E<gt> 1, pid =E<gt> $runner_pid, stamp =E<gt> $time} >>),
or C<undef> if the runner could not be reached.

=back

=cut

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

sub ping ($self) {
    return $self->_request('ping');
}

=head1 PRIVATE METHODS

=over 4

=item $conn = $client->connection

The (lazily opened) L<Test2::Harness2::Role::Service::Connection> to the runner,
or C<undef> if the runner was observed to have exited before it accepted. Delegates
to the shared L<Test2::Harness2::Runner::Role::SocketClient/_connect>, whose
runner-gone escape (C<_on_runner_gone>) sets C<runner_gone> and returns C<undef> so
submission becomes a no-op.

=item $client->_send($command, %args)

Send one one-way request. A no-op once the runner is observed gone before it ever
accepted (C<connection> returns C<undef>). Once connected the client conn back-
pressures a slow runner via the bounded-blocking flush (#108); if C<send_request>
still reports the connection closed mid-send (runner gone/wedged), this B<croaks>
rather than silently dropping the submission -- a dropped one-way frame carries no
ack, so a lost C<queue_task> would otherwise never run those tests yet report the
run green (#109).

=item $reply = $client->_request($command, %args)

Send one request and wait for the response whose C<request_id> matches, draining
the connection meanwhile. Returns the response payload, or C<undef> if the runner
could not be reached. Croaks on a closed connection or timeout.

=back

=cut

# How long to wait for the runner to bind/accept (and to reply) before giving up
# when we cannot otherwise tell the runner is gone. Env-overridable (pure superset:
# unset => 30s) so `yath stop`/`yath kill` regression tests that drive a fake,
# never-replying runner do not have to sit through the full 30s reply timeout
# (ticket #121); production behavior is unchanged.
sub CONNECT_TIMEOUT { $ENV{YATH_RUNNER_CONNECT_TIMEOUT} // 30 }

sub runner_gone ($self) { return $self->{+RUNNER_GONE} ? 1 : 0 }

# Identity prefix for the shared connect layer: this dialer announces "command-$$".
sub _identity_kind { 'command' }

# Runner-gone escape for the shared connect layer (SocketClient::_connect): the
# runner died before it ever started accepting, so stop trying. connection returns
# this undef and _send/_request short-circuit, making submission a no-op.
sub _on_runner_gone ($self, $path) {
    $self->{+RUNNER_GONE} = 1;
    return undef;
}

# The connect loop lives in Test2::Harness2::Runner::Role::SocketClient; expose it
# under the client's documented name.
sub connection ($self) { return $self->_connect }

sub _send ($self, $command, %args) {
    my $conn = $self->connection or return;
    # One-way submissions (queue_run/queue_task/stop_run/end_queue/halt_run, and
    # stop -- whose reply the client never waits for): want_reply => 0 so no
    # request_id is remembered as PENDING. The acknowledged two-way queries go
    # through _request (below), which keeps the default. (#134 finding 106)
    #
    # send_request returns the request_id on a delivered write and undef when the
    # connection closed during the send. The client connection is NOT owner_flushes,
    # so send_request already finished with the #108 bounded-blocking flush: a
    # merely-slow runner back-pressures here (the send waits) rather than dropping
    # the frame, so an undef means the runner is genuinely gone or wedged past its
    # stall window (or the queue blew past max_wbuf) -- never a transient EAGAIN. A
    # one-way submission carries no ack, so a silently-dropped frame would vanish:
    # a lost queue_task means those test files are never run yet the run still
    # reports green (a lost queue_run/stop_run/end_queue hangs the client waiting on
    # run_done). Croak instead so submission failure is loud, not a green run with
    # missing tests. submit_queue (App::Yath2::Client) runs these without an eval so
    # the croak aborts the run; the eval/alarm-wrapped callers (stop/kill/halt_run)
    # absorb it. (#109 finding 30)
    my $sent = $conn->send_request($command, %args, want_reply => 0);
    croak "runner connection closed while submitting '$command'; submission not delivered"
        unless defined $sent;

    return;
}

sub _request ($self, $command, %args) {
    my $conn = $self->connection or return undef;
    my $id   = $conn->send_request($command, %args);

    my $start = mono_time;    # reply window is a pure interval (#134 finding 104)
    while (1) {
        for my $event ($conn->drain) {
            next unless $event->{kind} eq 'response';
            return $event->{payload} if $event->{request_id} eq $id;
        }

        croak "runner closed the connection before sending a reply" if $conn->closed;
        croak "Timed out waiting for the runner's reply"
            if (mono_time - $start) > $self->CONNECT_TIMEOUT;

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
