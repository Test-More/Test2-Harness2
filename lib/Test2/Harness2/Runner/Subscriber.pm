package Test2::Harness2::Runner::Subscriber;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use File::Spec();
use IO::Select();
use Time::HiRes qw/sleep/;

use Test2::Collector::Util::Socket qw/connect_unix write_frame/;
use Test2::Collector::Util::Zstd qw/compress_blob/;
use Test2::Collector::Util::Zstd::FrameBuffer();
use Test2::Harness2::Util::JSON qw/encode_json decode_json/;

use Test2::Harness2::Runner::Monitor();

use Test2::Harness2::Util::HashBase qw{
    <workdir
    +socket_path
    +connection
    +frame_buffer
    +pending_recs
    +monitor
    +subscribed
    +closed
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::Subscriber - Client that mirrors a runner's canonical
state by subscribing to it: snapshot on connect, then forwarded mutations.

=head1 DESCRIPTION

A subscriber is a thin client of the runner service that keeps a local mirror of
the runner's canonical state. On L</subscribe> it connects to C<runner.socket>,
sends a C<subscribe> request, and reads back a serialized snapshot of the
runner's whole state, which it loads into a feed-mode
L<Test2::Harness2::Runner::Monitor> mirror. The runner thereafter B<forwards
every state-mutating transition> -- both the collector transitions other
collectors report and the mutations the runner originates itself (a job
dispatched / running / done) -- as self-contained zstd frames; L</poll> reads
them off the socket and feeds them into the mirror so its view stays whole (the
snapshot-plus-transitions contract).

The subscription connection stays open and receives asynchronous pushes, unlike
the one-shot request/reply submission client
(L<Test2::Harness2::Runner::Client>). The wire utilities are reused directly
from L<Test2-Collector|Test2::Collector>; this class carries no socket or zstd
copies.

This is the transient render source: the C<test> command mirrors the runner's
state through it and drives the renderers from the mirror plus each job's events
file (chunks 6a / 5g). The runner closing the socket (L</closed>) is the run's
completion signal.

=head1 SYNOPSIS

    my $sub = Test2::Harness2::Runner::Subscriber->new(workdir => $dir);
    $sub->subscribe;    # connect, snapshot, build the mirror

    while (...) {
        $sub->poll;     # read forwarded frames into the mirror
        my $mon = $sub->monitor;
        $_ and free_slot($_) for $mon->new_test_exits;
    }

=head1 PUBLIC METHODS

=over 4

=item socket_path

=item $path = $sub->socket_path

The runner socket path (C<< $workdir/runner.socket >>).

=item monitor

=item $mon = $sub->monitor

The local mirror (a L<Test2::Harness2::Runner::Monitor>) of the runner's state.
Populated by L</subscribe> and kept current by L</poll>.

=item subscribed

=item $bool = $sub->subscribed

True once L</subscribe> has connected and loaded the initial snapshot.

=item closed

=item $bool = $sub->closed

True once L</poll> has seen the runner close the socket (EOF). On the transient
path the runner shuts its service down when the run is done, so this is the
command's completion signal.

=item subscribe

=item $sub->subscribe

Connect to the runner, send the subscribe request, read the snapshot reply, and
load it into the mirror. Croaks if the socket does not carry a valid snapshot.

=item poll

=item $count = $sub->poll

Read whatever forwarded frames are available (non-blocking) and feed each into
the mirror. Returns the number of frames folded. A no-op until L</subscribe>.

=back

=cut

sub socket_path ($self) {
    return $self->{+SOCKET_PATH} //= File::Spec->catfile($self->{+WORKDIR}, 'runner.socket');
}

sub monitor ($self) {
    return $self->{+MONITOR} //= Test2::Harness2::Runner::Monitor->new;
}

sub subscribed ($self) { return $self->{+SUBSCRIBED} ? 1 : 0 }

sub closed ($self) { return $self->{+CLOSED} ? 1 : 0 }

sub subscribe ($self) {
    my $conn = $self->_connect;

    write_frame($conn, compress_blob(encode_json({request => 'subscribe'})));

    my $reply = $self->_read_one_frame($conn);
    croak "runner did not return a subscribe reply"
        unless ref($reply) eq 'HASH';
    croak "runner refused subscription: " . ($reply->{error} // 'unknown error')
        unless $reply->{ok};

    my $snapshot = $reply->{snapshot}
        or croak "runner subscribe reply carried no snapshot";

    $self->monitor->apply_snapshot($snapshot);
    $self->{+SUBSCRIBED} = 1;

    return;
}

sub poll ($self) {
    my $conn = $self->{+CONNECTION} or return 0;
    return 0 unless $self->{+SUBSCRIBED};

    my $fb  = $self->{+FRAME_BUFFER} //= Test2::Collector::Util::Zstd::FrameBuffer->new;
    my $mon = $self->monitor;

    my $sel   = IO::Select->new($conn);
    my $count = 0;

    while ($sel->can_read(0)) {
        my $buf = '';
        my $n   = sysread($conn, $buf, 65536);

        # EOF: the runner closed the socket. On the transient path the runner
        # shuts the service down once the run is done and its job children have
        # been reaped, so a clean EOF is the completion signal the command's
        # render loop watches for (replacing the retired gatherer's terminal
        # sentinel). undef is a would-block (already gated by can_read).
        unless ($n) {
            $self->{+CLOSED} = 1 if defined $n;
            last;
        }

        $fb->push_bytes($buf);
    }

    # Any frames that arrived batched with the synchronous snapshot reply were
    # parked here by _read_one_frame; fold them before the freshly-read ones so
    # ordering is preserved.
    my @recs = (@{$self->{+PENDING_RECS} //= []}, $fb->drain);
    $self->{+PENDING_RECS} = [];

    for my $rec (@recs) {
        my $payload;
        next unless eval { $payload = decode_json($rec->{payload}); 1 };
        $mon->feed($payload);
        $count++;
    }

    return $count;
}

=head1 PRIVATE METHODS

=over 4

=item $fh = $self->_connect

Open (and cache) the connection to the runner socket, blocking until it accepts.

=item $reply = $self->_read_one_frame($conn)

Read exactly one complete zstd frame off C<$conn> and return its decoded payload
(blocking until a whole frame arrives). Used for the synchronous snapshot reply.

=back

=cut

# How long to wait for the runner to bind and accept on its socket before giving
# up. The runner is a separate process; a brief window where the socket does not
# yet exist (or is bound but not yet accepting) is expected, so back off in
# sub-second steps rather than racing.
sub CONNECT_TIMEOUT { 30 }

sub _connect ($self) {
    return $self->{+CONNECTION} if $self->{+CONNECTION};

    my $path  = $self->socket_path;
    my $start = Time::HiRes::time();

    while (1) {
        if (-S $path) {
            my $conn;
            return $self->{+CONNECTION} = $conn
                if eval { $conn = connect_unix($path); 1 } && $conn;
        }

        croak "Timed out waiting for runner socket '$path' to accept connections"
            if (Time::HiRes::time() - $start) > $self->CONNECT_TIMEOUT;

        sleep 0.05;
    }
}

sub _read_one_frame ($self, $conn) {
    my $fb    = $self->{+FRAME_BUFFER} //= Test2::Collector::Util::Zstd::FrameBuffer->new;
    my $sel   = IO::Select->new($conn);
    my $start = Time::HiRes::time();

    while (1) {
        if ($sel->can_read(0.05)) {
            my $buf = '';
            my $n   = sysread($conn, $buf, 65536);
            croak "runner closed the connection before sending a reply"
                if defined $n && $n == 0;
            $fb->push_bytes($buf) if $n;
        }

        if (my @recs = $fb->drain) {
            my $rec = shift @recs;

            # Anything that arrived batched after the reply frame is parked for
            # the next poll, in order, so no forwarded mutation is lost.
            push @{$self->{+PENDING_RECS} //= []} => @recs;

            my $payload;
            croak "could not decode the runner's reply frame"
                unless eval { $payload = decode_json($rec->{payload}); 1 };
            return $payload;
        }

        croak "Timed out waiting for the runner's subscribe reply"
            if (Time::HiRes::time() - $start) > $self->CONNECT_TIMEOUT;
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
