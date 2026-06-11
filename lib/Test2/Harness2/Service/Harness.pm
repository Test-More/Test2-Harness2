package Test2::Harness2::Service::Harness;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use File::Path qw/make_path/;
use IO::Select ();

use Test2::Collector qw/spawn_collector/;
use Test2::Collector::Recorder::Zstd;
use Test2::Collector::Recorder::Socket;
use Test2::Collector::Util::JSON qw/decode_json/;
use Test2::Collector::Util::Socket qw/open_unix_listen/;
use Test2::Collector::Util::Zstd::FrameBuffer;

use Test2::Harness2::Collector::Monitor;
use Test2::Harness2::Run;

use Object::HashBase qw{
    <workdir
    <monitor
    +listen_sock
    +conns
    +queue
    +current
    +shutdown_requested
};

# How long one loop iteration blocks waiting for socket activity before
# checking state anyway.
use constant TICK_SECONDS => 0.2;

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Service::Harness - The harness service process: queue
runs, execute their jobs under collectors.

=head1 DESCRIPTION

This is the long-running service the L<Test2::Harness2> handle spawns
(itself wrapped in a non-test collector). It listens on a unix socket in
the workdir for client requests, each request a zstd-compressed JSON
object frame -- the same framing collectors use for events:

=over 4

=item C<< {queue_run => {...}} >>

Queue a run. The payload is the C<TO_JSON> form of a
L<Test2::Harness2::Run>; it is rehydrated here and its jobs are executed
in order, one at a time.

=item C<< {shutdown => 1} >>

No more runs are coming: finish everything queued, then exit.

=back

Each test job runs under its own collector (fork + exec of a fresh perl).
The collector records the full event stream to
C<< E<lt>workdirE<gt>/E<lt>run_uuidE<gt>/E<lt>job_uuidE<gt>-E<lt>tryE<gt>.jsonl.zst >>
and reports transitions back to this service's
L<Test2::Harness2::Collector::Monitor> over a second unix socket. The
monitor's C<harness_collector_finalized> message -- never C<waitpid> -- is
what marks a job complete; the collector is only reaped afterward.

=head1 SYNOPSIS

    use Test2::Harness2::Service::Harness;

    # Inside the collector-wrapped service process:
    my $exit = Test2::Harness2::Service::Harness->new(workdir => $workdir)->run;

=head1 ATTRIBUTES

=over 4

=item workdir

The harness working directory (required). The service creates its sockets
here and writes per-job events files below it.

=item monitor

The L<Test2::Harness2::Collector::Monitor> tracking job collectors.
Created by C<run>.

=back

=cut

sub init ($self) {
    croak "'workdir' is a required attribute"
        unless defined $self->{+WORKDIR} && length $self->{+WORKDIR};

    $self->{+CONNS} = {};
    $self->{+QUEUE} = [];

    return;
}

=head1 PUBLIC METHODS

=over 4

=item $path = $class_or_instance->socket_path($workdir)

=item $path = $instance->socket_path()

The request socket path for a given workdir (defaults to the instance's
own workdir). The L<Test2::Harness2> client uses the class form to know
where to connect.

=item $exit = $service->run

Run the service loop until a shutdown request has been received and every
queued run has finished. Returns the exit code for the service process
(C<0>).

=back

=cut

sub socket_path ($self, $workdir = undef) {
    $workdir //= ref($self) ? $self->{+WORKDIR} : croak "a workdir is required for the class form of socket_path";
    return "$workdir/harness.socket";
}

sub run ($self) {
    my $workdir = $self->{+WORKDIR};
    croak "workdir '$workdir' does not exist" unless -d $workdir;

    $self->{+MONITOR} = Test2::Harness2::Collector::Monitor->new(listen => "$workdir/harness_transitions.socket");

    $self->{+LISTEN_SOCK} = open_unix_listen($self->socket_path);
    $self->{+LISTEN_SOCK}->blocking(0);

    until ($self->_done) {
        IO::Select->new($self->_io_handles)->can_read(TICK_SECONDS);

        $self->_accept_clients;
        $self->_read_clients;
        $self->{+MONITOR}->poll;
        $self->_advance;
    }

    $self->_cleanup;

    return 0;
}

=head1 PRIVATE METHODS

=over 4

=item $bool = $self->_done

True once shutdown has been requested and there is no current job and no
queued run left.

=item @handles = $self->_io_handles

Every handle the loop should block on: the request socket, all client
connections, and the monitor's descriptors.

=cut

sub _done ($self) {
    return 0 unless $self->{+SHUTDOWN_REQUESTED};
    return 0 if $self->{+CURRENT};
    return 0 if @{$self->{+QUEUE}};
    return 1;
}

sub _io_handles ($self) {
    return (
        $self->{+LISTEN_SOCK},
        (map { $_->{sock} } values %{$self->{+CONNS}}),
        $self->{+MONITOR}->io_handles,
    );
}

=item $self->_accept_clients

Accept any pending client connections on the request socket
(non-blocking).

=item $self->_read_clients

Read every client connection, split complete frames, and dispatch each
decoded request. A connection at EOF is dropped.

=cut

sub _accept_clients ($self) {
    while (my $conn = $self->{+LISTEN_SOCK}->accept) {
        $conn->blocking(0);
        $self->{+CONNS}{$conn} = {
            sock   => $conn,
            buffer => Test2::Collector::Util::Zstd::FrameBuffer->new,
        };
    }

    return;
}

sub _read_clients ($self) {
    for my $key (keys %{$self->{+CONNS}}) {
        my $conn = $self->{+CONNS}{$key};

        my $buf = '';
        my $n   = sysread($conn->{sock}, $buf, 65536);

        # undef: would-block / transient -- try again next tick.
        next unless defined $n;

        if ($n == 0) {
            close($conn->{sock});
            delete $self->{+CONNS}{$key};
            next;
        }

        $conn->{buffer}->push_bytes($buf);
        for my $rec ($conn->{buffer}->drain) {
            warn "harness service: could not handle a client request: $@\n"
                unless eval { $self->_handle_request(decode_json($rec->{payload})); 1 };
        }
    }

    return;
}

=item $self->_handle_request($request)

Dispatch one decoded client request frame (C<queue_run> / C<shutdown>).
Unknown request shapes warn and are dropped.

=cut

sub _handle_request ($self, $request) {
    unless (ref($request) eq 'HASH') {
        warn "harness service: ignoring a non-hash request frame\n";
        return;
    }

    if (my $run_data = $request->{queue_run}) {
        push @{$self->{+QUEUE}} => {run => Test2::Harness2::Run->new(%$run_data), next => 0};
        return;
    }

    if ($request->{shutdown}) {
        $self->{+SHUTDOWN_REQUESTED} = 1;
        return;
    }

    warn "harness service: ignoring an unknown request frame (keys: " . join(',', sort keys %$request) . ")\n";
    return;
}

=item $self->_advance

The scheduler tick: finish the current job if its collector has
finalized, then start the next job of the current run (or of the next
queued run) when nothing is running. One job at a time, no concurrency.

=cut

sub _advance ($self) {
    if (my $current = $self->{+CURRENT}) {
        my %finalized = map { $_ => 1 } $self->{+MONITOR}->new_finalized;
        return unless $finalized{$current->{job_uuid}};

        # Completion came from the transitions channel above; the waitpid here
        # only reaps the collector we forked, and checks its health.
        waitpid($current->{pid}, 0);
        warn "harness service: the collector for job '$current->{job_uuid}' exited " . ($? >> 8) . "\n" if $?;

        $self->{+CURRENT} = undef;
    }

    my $queue = $self->{+QUEUE};
    return unless @$queue;

    # Queue entries are {run => $run, next => $index} -- the cursor lives in
    # the queue entry, never inside the immutable Run object.
    my $entry = $queue->[0];
    my $run   = $entry->{run};
    my $job   = $run->jobs->[$entry->{next}++];

    shift @$queue if $entry->{next} >= @{$run->jobs};

    $self->_start_job($run, $job);

    return;
}

=item $self->_start_job($run, $job)

Spawn the collector for one test job: events recorded to
C<< E<lt>run_uuidE<gt>/E<lt>job_uuidE<gt>-E<lt>tryE<gt>.jsonl.zst >> under
the workdir, transitions reported to the monitor's socket.

=cut

sub _start_job ($self, $run, $job) {
    my $dir = "$self->{+WORKDIR}/" . $run->run_uuid;
    make_path($dir) unless -d $dir;

    my $events_file = "$dir/" . $job->job_uuid . "-" . $job->try . ".jsonl.zst";

    my $pid = spawn_collector(
        is_test  => 1,
        name     => $job->test_file,
        uuid     => $job->job_uuid,
        run_uuid => $run->run_uuid,
        try      => $job->try,
        exec     => $self->_job_command($job),
        env      => $job->env_vars,
        recorder => Test2::Collector::Recorder::Zstd->new(file => $events_file),
        reporter => Test2::Collector::Recorder::Socket->new(paths => [$self->{+MONITOR}->socket_path]),
    );

    $self->{+CURRENT} = {pid => $pid, job_uuid => $job->job_uuid};

    return;
}

=item $argv = $self->_job_command($job)

Build the exec command for a job from its launch method. Only
C<fork_exec> exists: a fresh perl with the job's includes as C<-I> flags.

=cut

sub _job_command ($self, $job) {
    my $via = $job->via;
    return [$^X, (map { "-I$_" } @{$job->includes}), $job->test_file] if $via eq 'fork_exec';
    die "unknown job 'via' ($via)";
}

=item $self->_cleanup

Close and unlink the request socket and every client connection, and
close the monitor.

=back

=cut

sub _cleanup ($self) {
    for my $conn (values %{$self->{+CONNS}}) {
        close($conn->{sock});
    }
    $self->{+CONNS} = {};

    if (my $sock = delete $self->{+LISTEN_SOCK}) {
        close($sock);
        my $path = $self->socket_path;
        unlink $path if -e $path;
    }

    $self->{+MONITOR}->close if $self->{+MONITOR};

    return;
}

1;

__END__

=pod

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
