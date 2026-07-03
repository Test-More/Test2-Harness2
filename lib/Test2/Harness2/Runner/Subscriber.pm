package Test2::Harness2::Runner::Subscriber;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use File::Spec();
use Time::HiRes qw/sleep/;

use Test2::Harness2::Util qw/mono_time connect_unix_nb/;

use Test2::Harness2::Role::Service::Connection();
use Test2::Harness2::Runner::Monitor();

use Test2::Harness2::Util::HashBase qw{
    <workdir
    <run_id
    <drain_gate
    <liveness_check
    +identity
    +socket_path
    +connection
    +monitor
    +subscribed
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::Subscriber - Client that mirrors a runner's canonical
state by subscribing to it: snapshot on connect, then forwarded mutations.

=head1 DESCRIPTION

A subscriber keeps a local mirror of the runner's canonical state. On C<subscribe>
it connects to C<runner.socket>, exchanges the identity handshake
(ARCHITECTURE.md §5.2), sends a C<subscribe> request, and reads back the response
whose snapshot it loads into a feed-mode L<Test2::Harness2::Runner::Monitor>
mirror. The runner thereafter B<forwards every state-mutating transition> as
self-contained frames; C<poll> reads them off the connection and feeds them into
the mirror so its view stays whole.

With a C<run_id> the subscription is B<run-scoped> (the runner filters the
snapshot and the forwarded frames to that run plus the global bucket); with no
run_id it is B<global> and mirrors every run (the C<watch> path). The transport is
a L<Test2::Harness2::Role::Service::Connection>, which owns the framing, identity,
and the fact that messages may arrive in any order -- a transition batched with the
snapshot reply is folded too.

The runner closing the connection (C<closed>) is the transient path's completion
signal; on a persistent runner a run-scoped subscriber instead watches
C<run_done> (a C<harness_run_end> mutation).

=head1 PUBLIC METHODS

=over 4

=item $path = $sub->socket_path

The runner socket path (C<< $workdir/runner.socket >>).

=item $id = $sub->run_id

The run this subscription is scoped to, or C<undef> for a global subscription.

=item $mon = $sub->monitor

The local mirror of the runner's state.

=item $bool = $sub->subscribed

True once C<subscribe> has connected and loaded the initial snapshot.

=item $bool = $sub->closed

True once the runner has closed the connection (EOF).

=item $bool = $sub->run_done

True once the runner has announced this subscription's run as finished.

=item $sub->subscribe

Connect, exchange identity, send the subscribe request, read the snapshot reply,
and load it into the mirror. Croaks if the runner does not return a snapshot.

=item $count = $sub->poll

Read whatever forwarded frames are available (non-blocking) and feed each into the
mirror. Returns the number folded. A no-op until C<subscribe>.

=back

=cut

sub socket_path ($self) {
    return $self->{+SOCKET_PATH} //= File::Spec->catfile($self->{+WORKDIR}, 'runner.socket');
}

sub identity ($self) {
    return $self->{+IDENTITY} //= "subscriber-$$";
}

sub monitor ($self) {
    return $self->{+MONITOR} //= Test2::Harness2::Runner::Monitor->new;
}

sub subscribed ($self) { return $self->{+SUBSCRIBED} ? 1 : 0 }

sub closed ($self) {
    my $conn = $self->{+CONNECTION} or return 0;
    return $conn->closed;
}

sub run_done ($self) {
    return 0 unless defined $self->{+RUN_ID};
    return $self->monitor->run_done($self->{+RUN_ID});
}

sub subscribe ($self) {
    my $conn = $self->_connect;
    my $mon  = $self->monitor;

    my %args;
    $args{run_id} = $self->{+RUN_ID} if defined $self->{+RUN_ID};
    # A "drain gate" subscriber (e.g. a DB logger) asks the persistent runner to
    # defer workdir cleanup until it disconnects; a plain render subscriber does not
    # (it never disconnects until the runner closes the socket, so gating on it would
    # deadlock the shutdown wait).
    $args{drain_gate} = 1 if $self->{+DRAIN_GATE};
    my $id = $conn->send_request('subscribe', %args);

    # A forwarded transition can arrive batched with (or before) the snapshot
    # response in a single drain. The snapshot is the baseline and the transitions
    # are deltas on top of it, so park every transition until the snapshot lands,
    # then apply the snapshot and replay the parked deltas in order -- dropping a
    # transition that shared the response's batch would lose state.
    my @deltas;
    my $start = mono_time;    # reply window is a pure interval (#134 finding 104)
    while (1) {
        my $snapshot;
        for my $event ($conn->drain) {
            push(@deltas, $event->{payload}), next if $event->{kind} eq 'transition';

            next unless $event->{kind} eq 'response' && $event->{request_id} eq $id;
            $snapshot = $event->{payload}{snapshot}
                or croak "runner subscribe reply carried no snapshot";
        }

        if ($snapshot) {
            $mon->apply_snapshot($snapshot);
            $mon->feed($_) for @deltas;
            $self->{+SUBSCRIBED} = 1;
            return;
        }

        croak "runner closed the connection before the subscribe reply" if $conn->closed;
        croak "Timed out waiting for the runner's subscribe reply"
            if (mono_time - $start) > $self->CONNECT_TIMEOUT;

        sleep 0.01;
    }
}

sub poll ($self) {
    my $conn = $self->{+CONNECTION} or return 0;
    return 0 unless $self->{+SUBSCRIBED};

    my $mon   = $self->monitor;
    my $count = 0;

    for my $event ($conn->drain) {
        next unless $event->{kind} eq 'transition';
        $mon->feed($event->{payload});
        $count++;
    }

    return $count;
}

=head1 PRIVATE METHODS

=over 4

=item $conn = $self->_connect

Open the connection to the runner -- retrying a bounded non-blocking connect
(C<connect_unix_nb>, #157) until it accepts or the C<CONNECT_TIMEOUT> deadline (or
C<liveness_check>) gives up, so a bound-but-wedged runner can never hang the dial --
wrap it in a L<Test2::Harness2::Role::Service::Connection>, and announce our
identity. We do not block for the runner's identity; C<subscribe> drains it while
waiting for the snapshot.

=back

=cut

sub CONNECT_TIMEOUT { 30 }

# Per-attempt bound for the non-blocking connect_unix_nb dial (ticket #157). A
# runner that is accepting completes the connect near-instantly; this bound only
# fires when the connect stays pending -- a bound-but-wedged runner with a full
# accept backlog -- so each attempt returns promptly and _connect re-checks
# liveness and the outer CONNECT_TIMEOUT deadline instead of blocking forever in
# the kernel's unix_wait_for_peer (the old blocking connect could not time out).
sub CONNECT_ATTEMPT_TIMEOUT { 0.5 }

# Run the optional liveness_check coderef; true when absent (assume alive). Mirror
# of Runner::Client::_runner_alive so a subscriber can fast-fail when the runner
# died after binding the socket, instead of stalling the full CONNECT_TIMEOUT.
# (#134 finding 108)
sub _runner_alive ($self) {
    my $check = $self->{+LIVENESS_CHECK} or return 1;    # no check: assume alive
    return $self->$check ? 1 : 0;
}

sub _connect ($self) {
    return $self->{+CONNECTION} if $self->{+CONNECTION} && !$self->{+CONNECTION}->closed;

    my $path  = $self->socket_path;
    my $start = mono_time;    # connect window is a pure interval (#134 finding 104)

    my $fh;
    while (1) {
        if (-S $path) {
            # Bounded NON-BLOCKING connect (#157): a blocking connect to a
            # bound-but-wedged runner (full accept backlog) blocks forever in the
            # kernel, so the CONNECT_TIMEOUT deadline below could never fire. Each
            # attempt returns promptly; connect_unix_nb yields a connected,
            # already-non-blocking socket on success.
            my ($sock) = connect_unix_nb($path, $self->CONNECT_ATTEMPT_TIMEOUT);
            if ($sock) { $fh = $sock; last }
        }

        # A runner that died after binding the socket (or before it ever bound)
        # would otherwise cost a flat CONNECT_TIMEOUT stall here. If the caller
        # supplied a liveness_check, fail fast the moment it reports the runner
        # gone. (#134 finding 108)
        croak "Runner is gone; cannot subscribe via '$path'" unless $self->_runner_alive;

        croak "Timed out waiting for runner socket '$path' to accept connections"
            if (mono_time - $start) > $self->CONNECT_TIMEOUT;

        sleep 0.05;
    }

    my $conn = Test2::Harness2::Role::Service::Connection->new(
        fh          => $fh,
        outbound    => 1,
        my_identity => $self->identity,
    );

    return $self->{+CONNECTION} = $conn;
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
