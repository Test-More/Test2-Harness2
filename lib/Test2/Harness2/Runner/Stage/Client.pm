package Test2::Harness2::Runner::Stage::Client;
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
    <stage
    <liveness_check
    +socket_path
    +connection
    +stage_gone
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::Stage::Client - Runner-side client that dispatches jobs
to a preload stage over its unix socket.

=head1 DESCRIPTION

In the transient runner, each global preload stage runs as a service that binds
C<< preload-E<lt>stageE<gt>.socket >> in the workdir (see
L<Test2::Harness2::Runner::Stage>). The runner's in-process scheduler no longer
enqueues C<start_task> actions for the stage to poll out of C<dispatch.jsonl>;
instead it B<connects out> to the stage's socket and dispatches the resolved
task as a request frame. This class is that connecting-out client.

A stage binds its socket only once it has fully preloaded and is ready to fork
tests, so "the socket accepts a connection" is the stage's readiness signal. The
client retries the connect with a short backoff until the socket accepts, an
optional C<liveness_check> reports the stage process gone, or a bounded timeout
is reached.

Requests are one-way (the stage sends no reply); a single connection is reused
so the stage applies dispatches in send order. Each request is framed,
zstd-compressed into one self-contained frame, and written with the shared
L<Test2::Collector::Util::Socket> framing.

=head1 SYNOPSIS

    my $client = Test2::Harness2::Runner::Stage::Client->new(
        workdir        => $dir,
        stage          => 'default',
        liveness_check => sub { $runner->stage_alive('default') },
    );
    $client->run_task($task, $run_item);

    warn "stage died before accepting" if $client->stage_gone;

=head1 PUBLIC METHODS

=over 4

=item $path = $client->socket_path

The stage socket path (C<< $workdir/preload-E<lt>stageE<gt>.socket >>).

=item $bool = $client->stage_gone

True once the stage was observed to have exited before the client could connect.

=item $client->run_task($task, $run)

Dispatch one resolved task (and the run definition it belongs to) to the stage
for forking.

=item $client->stop

Ask the stage to shut down its service loop cleanly (sent at run end so an idle
stage exits instead of blocking the runner's wait).

=back

=cut

sub socket_path ($self) {
    return $self->{+SOCKET_PATH} //= File::Spec->catfile($self->{+WORKDIR}, "preload-$self->{+STAGE}.socket");
}

sub run_task ($self, $task, $run) {
    $self->_send({request => 'run_task', task => $task, run => $run});
    return;
}

sub stop ($self) {
    $self->_send({request => 'stop'});
    return;
}

=head1 PRIVATE METHODS

=over 4

=item $fh = $client->connection

The (lazily opened) connection to the stage socket, or C<undef> if the stage was
observed to have exited before it accepted. The stage may still be preloading
when the runner first dispatches to it, so this retries with a short backoff
until the socket accepts (the readiness signal), the liveness check reports the
stage gone, or the bounded timeout is reached.

=item $bool = $client->_stage_alive

Run the C<liveness_check> coderef (true when absent).

=item $client->_send($request)

Frame, compress, and write one request over the connection (a no-op once the
stage is gone).

=back

=cut

# How long to wait for a stage to bind and start accepting on its socket before
# giving up when we cannot otherwise tell the stage is gone. A stage is a
# separate process that may still be preloading, so a window where the socket
# does not yet exist (or is bound but not yet accepting) is expected; back off in
# sub-second steps rather than racing.
sub CONNECT_TIMEOUT { 30 }

sub stage_gone ($self) { return $self->{+STAGE_GONE} ? 1 : 0 }

sub _stage_alive ($self) {
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

        # If the stage died before it ever started accepting connections there is
        # nothing to dispatch to; stop trying so the dispatch becomes a no-op and
        # the runner can surface the stage's failure (its collector / reaped exit)
        # instead of hanging here.
        unless ($self->_stage_alive) {
            $self->{+STAGE_GONE} = 1;
            return undef;
        }

        croak "Timed out waiting for stage socket '$path' to accept connections"
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
