package Test2::Harness2::Util::FdPass::Control;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Errno qw/EINTR EAGAIN EWOULDBLOCK/;
use Fcntl qw/F_GETFL F_SETFL O_NONBLOCK/;

use Test2::Harness2::Util::JSON qw/encode_json decode_json/;

use Test2::Harness2::Util::HashBase qw{
    <fh
    +buffer
    +closed
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::FdPass::Control - The dedicated control mini-protocol for
C<yath spawn>, layered on the same socket after the C<SCM_RIGHTS> descriptor pass.

=head1 DESCRIPTION

C<yath spawn> uses one connection in two phases. Phase one is the C<SCM_RIGHTS>
descriptor pass (L<Test2::Harness2::Util::FdPass>): the command sends its real
C<STDIN> / C<STDOUT> / C<STDERR> and the supervisor receives them. After that the
B<same> socket becomes a tiny framed control channel that carries the supervisor
pid, signals the command forwards to the spawned process group, and the child's
raw wait status at exit.

This is deliberately B<not> L<Test2::Harness2::Role::Service::Connection>: that
transport requires an identity frame as the very first bytes on the socket, which
would collide with the raw single payload byte L<IO::FDPass> writes alongside each
passed descriptor. This channel assumes the descriptors have already been passed
and the socket is clean, so it needs no identity exchange.

=head2 Wire format

Each message is one JSON object, length-prefixed:

    <decimal-length>\0<json-bytes>

A C<\0> separates the ASCII decimal byte-length from the JSON payload. Framing is
self-describing and order-preserving on a stream socket. The message kinds:

    { hello       => { pid => $supervisor_pid } }      # supervisor -> command
    { signal      => { signal => $name } }             # command    -> supervisor
    { exit_status => { status => $raw_wait_status } }  # supervisor -> command

C<read_message> on a peer that has closed the socket returns nothing (EOF). The
supervisor treats that EOF as "the command/terminal died" and kills the spawned
process group; the command never sees an EOF before the C<exit_status> frame on a
healthy run.

=head1 SYNOPSIS

    my $ctl = Test2::Harness2::Util::FdPass::Control->new(fh => $sock);

    # supervisor:
    $ctl->send_hello($$);
    $ctl->send_exit_status($?);

    # command:
    my $msg = $ctl->read_message;   # blocking, undef on EOF
    $ctl->send_signal('INT');

=head1 ATTRIBUTES

=over 4

=item $fh = $ctl->fh

The underlying connected socket (shared with the descriptor-pass phase).

=back

=cut

sub init ($self) {
    croak "'fh' is a required attribute" unless defined $self->{+FH};
    $self->{+BUFFER} //= '';
    $self->{+CLOSED} //= 0;
    return;
}

=head1 PUBLIC METHODS

=over 4

=item $bool = $ctl->closed

True once the channel has seen EOF or a fatal read/write error.

=item $ctl->send_hello($pid)

Supervisor side: announce the supervisor's pid so the command knows the process it
is talking to.

=item $ctl->send_signal($name)

Command side: forward a trapped signal by name (e.g. C<INT>) to the supervisor,
which relays it to the spawned process group.

=item $ctl->send_exit_status($status)

Supervisor side: report the spawned child's B<raw> wait status (C<$?> from the
C<waitpid>), so the command can re-raise a signal death rather than report only a
numeric exit code.

=item $msg = $ctl->read_message

Block until one complete message arrives and return it as a hashref, or return
nothing on EOF / a closed channel. Buffers partial reads across calls.

=item $msg = $ctl->read_message_nb

Non-blocking variant: return a decoded message if one is fully buffered/available,
an empty list if nothing is ready yet, and nothing (with C<closed> set) on EOF.

=item $ctl->close

Close the underlying socket (idempotent).

=back

=cut

sub closed ($self) { return $self->{+CLOSED} ? 1 : 0 }

sub send_hello       ($self, $pid)    { return $self->_send({hello       => {pid    => $pid}}) }
sub send_signal      ($self, $name)   { return $self->_send({signal      => {signal => $name}}) }
sub send_exit_status ($self, $status) { return $self->_send({exit_status => {status => $status}}) }

sub close ($self) {
    return if $self->{+CLOSED};
    $self->{+CLOSED} = 1;
    eval { CORE::close($self->{+FH}); 1 };
    return;
}

sub read_message ($self) {
    while (1) {
        my $msg = $self->_take_message;
        return $msg if defined $msg;
        return if $self->{+CLOSED};

        my $got = $self->_fill(1);
        return if $self->{+CLOSED};
        next if $got;
    }
}

sub read_message_nb ($self) {
    my $msg = $self->_take_message;
    return $msg if defined $msg;
    return if $self->{+CLOSED};

    $self->_fill(0);
    return if $self->{+CLOSED};

    $msg = $self->_take_message;
    return $msg if defined $msg;

    return ();
}

=head1 PRIVATE METHODS

=over 4

=item $self->_send($message)

Frame, JSON-encode, and write one message hashref. Closes the channel (and
returns false) on a write failure (a vanished peer); returns true on success.

=item $got = $self->_fill($blocking)

Read available bytes onto the internal buffer. With C<$blocking> true it waits for
at least one read; non-blocking returns immediately. Sets C<closed> on EOF or a
fatal error. Returns the number of bytes read.

=item $message = $self->_take_message

Pull one complete framed message out of the buffer, or C<undef> when no full frame
is buffered yet.

=item $self->_set_blocking($bool)

Toggle the underlying descriptor's blocking flag via C<fcntl> (not
C<< IO::Handle->blocking >>, which can no-op on a raw, unblessed socketpair
handle).

=back

=cut

sub _send ($self, $message) {
    return 0 if $self->{+CLOSED};

    # Restore blocking before writing: a prior read_message_nb leaves the fh
    # O_NONBLOCK (_fill(0) -> _set_blocking(0)), which would make this syswrite fail
    # EAGAIN on a full send buffer -- treated as fatal below and closing the channel,
    # so send_hello/send_signal/send_exit_status could silently drop a frame (the
    # command would then see a frameless EOF and misreport a healthy exit as a vanish).
    $self->_set_blocking(1);

    my $json  = encode_json($message);
    my $frame = length($json) . "\0" . $json;

    my $ok = eval {
        my $off = 0;
        while ($off < length($frame)) {
            my $w = syswrite($self->{+FH}, $frame, length($frame) - $off, $off);
            unless (defined $w) {
                next if $! == EINTR;
                die "control write failed: $!";
            }
            $off += $w;
        }
        1;
    };

    $self->close unless $ok;

    return $ok ? 1 : 0;
}

sub _fill ($self, $blocking) {
    my $fh = $self->{+FH};

    $self->_set_blocking($blocking);

    my $buf = '';
    my $n   = sysread($fh, $buf, 65536);

    unless (defined $n) {
        return 0 if $! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR;
        $self->close;
        return 0;
    }

    if ($n == 0) {    # EOF
        $self->close;
        return 0;
    }

    $self->{+BUFFER} .= $buf;
    return $n;
}

sub _set_blocking ($self, $blocking) {
    my $fh = $self->{+FH};

    # Use fcntl directly rather than IO::Handle->blocking: a raw socketpair handle
    # is not always blessed into IO::Handle, so ->can('blocking') can be false and
    # the toggle would silently no-op (leaving a blocking read to hang).
    my $flags = fcntl($fh, F_GETFL, 0);
    return unless defined $flags;

    my $want = $blocking ? ($flags & ~O_NONBLOCK) : ($flags | O_NONBLOCK);
    fcntl($fh, F_SETFL, $want) if $want != $flags;

    return;
}

sub _take_message ($self) {
    my $sep = index($self->{+BUFFER}, "\0");
    return undef if $sep < 0;

    my $len = substr($self->{+BUFFER}, 0, $sep);
    return undef unless $len =~ /^\d+$/;

    my $need = $sep + 1 + $len;
    return undef if length($self->{+BUFFER}) < $need;

    my $json = substr($self->{+BUFFER}, $sep + 1, $len);
    substr($self->{+BUFFER}, 0, $need) = '';

    my $message;
    my $ok = eval { $message = decode_json($json); 1 };
    return $ok && ref($message) eq 'HASH' ? $message : {};
}

1;

__END__

=pod

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
