package Test2::Harness2::Runner::Client;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use File::Spec();
use Time::HiRes qw/sleep/;

use Test2::Collector::Util::Socket qw/connect_unix write_frame/;
use Test2::Collector::Util::Zstd qw/compress_blob/;
use Test2::Harness2::Util::JSON qw/encode_json/;

use Test2::Harness2::Util::HashBase qw{
    <workdir
    <liveness_check
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

A transient C<yath test> command is a thin client of the runner service: instead
of writing the run, its tasks, and the queue terminator into C<dispatch.jsonl>
for a runner to poll, it connects to the runner's C<runner.socket> and sends them
as request frames. The runner's request handlers fold them into its canonical
in-process state object.

This class exposes the same submission API the runner's
L<Test2::Harness2::Runner::State> does (C<queue_run>, C<queue_task>,
C<stop_run>, C<end_queue>) so it can substitute for that state object as the
command's submission target. Each call frames a request as
C<< {request =E<gt> $type, ...} >>, compresses it into one self-contained zstd
frame, and writes it with the shared L<Test2::Collector::Util::Socket> framing.
The requests are one-way (the runner sends no reply); a single connection is
reused so the runner applies them in send order.

The runner is a separate process spawned just before submission, so it may not
be listening yet when the client first connects; the client retries with a short
backoff. An optional C<liveness_check> coderef lets the caller tell the client
the runner has died before it ever accepted (e.g. a broken preload), so the
client stops trying and submission becomes a no-op rather than hanging or dying.

=head1 SYNOPSIS

    my $client = Test2::Harness2::Runner::Client->new(
        workdir        => $dir,
        liveness_check => sub { $ipc->wait; $ipc->{PROCS}{$runner_pid} ? 1 : 0 },
    );
    $client->queue_run($run_item);
    $client->queue_task($task) for @tasks;
    $client->stop_run($run_id);
    $client->end_queue;

    warn "runner died before accepting" if $client->runner_gone;

=head1 PUBLIC METHODS

=over 4

=item $path = $client->socket_path

The runner socket path (C<< $workdir/runner.socket >>).

=item $bool = $client->runner_gone

True once the runner was observed to have exited before the client could connect.

=item $coderef = $client->liveness_check

The optional caller-supplied check that returns true while the runner is alive.

=item $client->queue_run($run)

Submit the run definition.

=item $client->queue_task($task)

Submit one task.

=item $client->queue_spawn($spawn)

Submit one spawn request (C<yath spawn>).

=item $client->stop_run($run_id)

Signal that no more tasks will be queued for the given run.

=item $client->end_queue

Signal that no more runs/work will be submitted.

=item $client->stop

Ask the runner service to shut down gracefully (the Role::Service built-in
C<stop> request). Used by C<yath stop> to wind a persistent runner down over the
socket.

=item $client->halt_run($run_id)

Ask the runner to halt the run (used on a caught signal).

=item $client->stop_task($job_id)

Report (from a preload stage) that a dispatched job finished and its slot/resources
should be released in the runner's scheduler state.

=item $client->retry_task($job_id)

Report (from a preload stage) that a dispatched job finished but should be retried;
the runner re-queues it for dispatch.

=item $client->stage_ready($stage)

Report (from a preload stage) that the stage has bound its socket and is ready to
be scheduled.

=item $client->stage_down($stage)

Report (from a preload stage) that the stage is shutting down.

=item $client->reload($stage, $data)

Forward (from a monitored preload stage) a reload/monitor notification so the
runner's reload state stays current.

=back

=cut

sub socket_path ($self) {
    return $self->{+SOCKET_PATH} //= File::Spec->catfile($self->{+WORKDIR}, 'runner.socket');
}

sub queue_run ($self, $run) {
    $self->_send({request => 'queue_run', run => $run});
    return;
}

sub queue_task ($self, $task) {
    $self->_send({request => 'queue_task', task => $task});
    return;
}

sub queue_spawn ($self, $spawn) {
    $self->_send({request => 'queue_spawn', spawn => $spawn});
    return;
}

sub stop_run ($self, $run_id) {
    $self->_send({request => 'stop_run', run_id => $run_id});
    return;
}

sub end_queue ($self) {
    $self->_send({request => 'end_queue'});
    return;
}

sub stop ($self) {
    $self->_send({request => 'stop'});
    return;
}

sub halt_run ($self, $run_id) {
    $self->_send({request => 'halt_run', run_id => $run_id});
    return;
}

sub stop_task ($self, $job_id) {
    $self->_send({request => 'stop_task', job_id => $job_id});
    return;
}

sub retry_task ($self, $job_id) {
    $self->_send({request => 'retry_task', job_id => $job_id});
    return;
}

sub reload ($self, $stage, $data) {
    $self->_send({request => 'reload', stage => $stage, data => $data});
    return;
}

sub stage_ready ($self, $stage) {
    $self->_send({request => 'stage_ready', stage => $stage});
    return;
}

sub stage_down ($self, $stage) {
    $self->_send({request => 'stage_down', stage => $stage});
    return;
}

=head1 PRIVATE METHODS

=over 4

=item $fh = $client->connection

The (lazily opened) connection to the runner socket, or C<undef> if the runner
was observed to have exited before it accepted. The runner is spawned separately
and may not be listening yet, so this retries with a short backoff until the
socket accepts, the liveness check reports the runner gone, or the bounded
timeout is reached.

=item $bool = $client->_runner_alive

Run the C<liveness_check> coderef (true when absent).

=item $client->_send($request)

Frame, compress, and write one request over the connection (a no-op once the
runner is gone).

=back

=cut

# How long to wait for the runner to bind and start accepting on its socket
# before giving up when we cannot otherwise tell the runner is gone. The runner
# is a separate process spawned just before submission, so a brief window where
# the socket does not yet exist (or is bound but not yet accepting, e.g. while the
# runner is still preloading) is expected; back off in sub-second steps rather
# than racing.
sub CONNECT_TIMEOUT { 30 }

# True once the runner is known to have exited before we could connect (e.g. a
# broken preload that killed the runner during startup). In that case there is no
# state to submit to; the caller should stop submitting and let the gatherer
# surface the runner's own failure.
sub runner_gone ($self) { return $self->{+RUNNER_GONE} ? 1 : 0 }

sub _runner_alive ($self) {
    my $check = $self->{+LIVENESS_CHECK} or return 1;    # no check: assume alive
    return $self->$check ? 1 : 0;
}

sub connection ($self) {
    return $self->{+CONNECTION} if $self->{+CONNECTION};

    my $path  = $self->socket_path;
    my $start = Time::HiRes::time();

    while (1) {
        if (-S $path) {
            my $conn;
            my $ok = eval { $conn = connect_unix($path); 1 };
            return $self->{+CONNECTION} = $conn if $ok && $conn;
        }

        # If the runner died before it ever started accepting connections there
        # is nothing to connect to; stop trying so submission becomes a no-op and
        # the gatherer can report the runner's failure instead of us hanging.
        unless ($self->_runner_alive) {
            $self->{+RUNNER_GONE} = 1;
            return undef;
        }

        croak "Timed out waiting for runner socket '$path' to accept connections"
            if (Time::HiRes::time() - $start) > $self->CONNECT_TIMEOUT;

        sleep 0.05;
    }
}

sub _send ($self, $request) {
    my $conn = $self->connection or return;
    write_frame($conn, compress_blob(encode_json($request)));
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
