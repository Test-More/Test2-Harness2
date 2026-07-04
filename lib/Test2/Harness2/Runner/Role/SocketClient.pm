package Test2::Harness2::Runner::Role::SocketClient;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use File::Spec();
use Time::HiRes qw/sleep/;

use Test2::Harness2::Util qw/mono_time connect_unix_nb/;

use Test2::Harness2::Role::Service::Connection();

use Role::Tiny;

# Constant-only slots: this role shares the composing dialer's hashref. Declaring
# the slot keys it touches as HashBase constants gives compile-time/grep safety on
# the bare-string keys without changing the slots themselves (the constant is the
# lowercased name). Each dialer (Client / Subscriber) declares the same slots and
# the values match.
use Test2::Harness2::Util::HashBase qw{
    +workdir
    +liveness_check
    +identity
    +socket_path
    +connection
};

requires qw/CONNECT_TIMEOUT _identity_kind _on_runner_gone/;

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::Role::SocketClient - Shared connect layer for the
runner's unix-socket dialers (Client / Subscriber).

=head1 DESCRIPTION

L<Test2::Harness2::Runner::Client> and L<Test2::Harness2::Runner::Subscriber> both
dial the runner's C<runner.socket>: they derive the same socket path, announce the
same C<< <kind>-$$ >> identity, and run the same bounded retry/backoff connect loop
(the runner is spawned just before submission, so it may not be listening yet). This
role carries that shared layer so the two dialers keep only what genuinely differs.

Two things DO differ, so they stay with the composing class (the role C<requires>
them): C<CONNECT_TIMEOUT> (the Client's is env-overridable via
C<YATH_RUNNER_CONNECT_TIMEOUT> per ticket TODO-121; the Subscriber's is flat) and the
runner-gone escape (C<_on_runner_gone>: the Client stops trying so submission
becomes a no-op; the Subscriber croaks).

=head1 SYNOPSIS

    package Test2::Harness2::Runner::Client;
    use Role::Tiny::With;
    with 'Test2::Harness2::Runner::Role::SocketClient';

    sub CONNECT_TIMEOUT  { $ENV{YATH_RUNNER_CONNECT_TIMEOUT} // 30 }
    sub _identity_kind   { 'command' }
    sub _on_runner_gone ($self, $path) { $self->{+RUNNER_GONE} = 1; return undef }

=head1 PROVIDED METHODS

=over 4

=item $path = $self->socket_path

The runner socket path (C<< $workdir/runner.socket >>).

=item $id = $self->identity

The identity this dialer announces: C<< <kind>-$$ >>, where C<< <kind> >> comes
from the composing class's C<_identity_kind>.

=item $bool = $self->_runner_alive

Run the optional C<liveness_check> coderef (true when absent).

=item $conn = $self->_connect

The (lazily opened) L<Test2::Harness2::Role::Service::Connection> to the runner.
Retries a bounded non-blocking connect (C<connect_unix_nb>, TODO-157) with a short
backoff until it accepts, then exchanges identity before returning. If the optional
C<liveness_check> reports the runner gone before it ever accepted, defers to the
composing class's C<_on_runner_gone>.

=back

=head1 REQUIRED METHODS

=over 4

=item $secs = $self->CONNECT_TIMEOUT

The outer connect/reply deadline (diverges between the dialers, see DESCRIPTION).

=item $kind = $self->_identity_kind

The identity prefix (C<command> / C<subscriber>).

=item $self->_on_runner_gone($path)

What to do when the runner was observed to have exited before it ever accepted.

=back

=cut

# Per-attempt bound for the non-blocking connect_unix_nb dial (ticket TODO-157). A
# runner that is accepting completes the connect near-instantly; this bound only
# fires when the connect stays pending -- a bound-but-wedged runner with a full
# accept backlog -- so each attempt returns promptly and the loop re-checks
# liveness and the outer CONNECT_TIMEOUT deadline instead of blocking forever in
# the kernel's unix_wait_for_peer (the old blocking connect could not time out).
sub CONNECT_ATTEMPT_TIMEOUT { 0.5 }

sub socket_path ($self) {
    return $self->{+SOCKET_PATH} //= File::Spec->catfile($self->{+WORKDIR}, 'runner.socket');
}

sub identity ($self) {
    return $self->{+IDENTITY} //= $self->_identity_kind . "-$$";
}

sub _runner_alive ($self) {
    my $check = $self->{+LIVENESS_CHECK} or return 1;    # no check: assume alive
    return $self->$check ? 1 : 0;
}

sub _connect ($self) {
    my $conn = $self->{+CONNECTION};
    return $conn if $conn && !$conn->closed;

    my $path  = $self->socket_path;
    my $start = mono_time;    # connect window is a pure interval (TODO-134 finding 104)

    my $fh;
    while (1) {
        if (-S $path) {
            # Bounded NON-BLOCKING connect (TODO-157): a blocking connect to a
            # bound-but-wedged runner (full accept backlog) blocks forever in the
            # kernel, so the CONNECT_TIMEOUT deadline below could never fire. Each
            # attempt returns promptly; connect_unix_nb yields a connected,
            # already-non-blocking socket on success.
            my ($sock) = connect_unix_nb($path, $self->CONNECT_ATTEMPT_TIMEOUT);
            if ($sock) { $fh = $sock; last }
        }

        # The runner died before it ever started accepting: there is nothing to
        # connect to. Let the composing dialer decide -- the Client stops trying so
        # submission becomes a no-op (returns undef), the Subscriber croaks.
        return $self->_on_runner_gone($path) unless $self->_runner_alive;

        croak "Timed out waiting for runner socket '$path' to accept connections"
            if (mono_time - $start) > $self->CONNECT_TIMEOUT;

        sleep 0.05;
    }

    # The Connection sends our identity (the runner needs it before any request). We
    # do NOT block waiting for the runner's identity in return: the client matches
    # responses by request_id, never by peer identity, so it needs nothing back to
    # proceed. (Blocking here would also deadlock a single-threaded caller that pumps
    # the runner only after this returns.) The two-way reply-wait loops drain the
    # reply -- and the runner's identity -- when they wait for their response.
    return $self->{+CONNECTION} = Test2::Harness2::Role::Service::Connection->new(
        fh          => $fh,
        outbound    => 1,
        my_identity => $self->identity,
    );
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
