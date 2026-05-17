package App::Yath2::Spawn::FdPass;
use strict;
use warnings;

our $VERSION = '2.000013';

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Spawn::FdPass - SCM_RIGHTS file-descriptor passing over a Unix socket.

=head1 DESCRIPTION

Thin wrapper around L<Socket::MsgHdr> that ships a fixed list of file
descriptors across a Unix-domain socket via C<SCM_RIGHTS> ancillary
data. Used by L<App::Yath2::Spawn::Client> and the preload service's
script-spawn grandchild to hand STDIN/STDOUT/STDERR across processes.

=head1 EXPORTS

C<send_fds>, C<recv_fds>.

=cut

use Carp qw/croak/;
use Socket qw/SOL_SOCKET SCM_RIGHTS/;
use Socket::MsgHdr ();
use Importer Importer => 'import';

our @EXPORT_OK = qw/send_fds recv_fds/;

=head2 send_fds($sock, \@fds)

Sends each integer FD in C<\@fds> across the Unix socket as an
C<SCM_RIGHTS> ancillary message. A single C<\0> payload byte
accompanies the control data because most kernels refuse to deliver
an SCM_RIGHTS message with zero-length normal data. The receiver
sees fresh FD numbers pointing at the same underlying file objects.

=cut

sub send_fds {
    my ($sock, $fds) = @_;
    croak "send_fds: socket required"       unless defined $sock;
    croak "send_fds: fds arrayref required" unless ref($fds) eq 'ARRAY' && @$fds;

    my $msg = Socket::MsgHdr->new(buf => "\0");
    $msg->cmsghdr(SOL_SOCKET, SCM_RIGHTS, pack('i*', @$fds));

    my $sent = Socket::MsgHdr::sendmsg($sock, $msg, 0);
    croak "sendmsg failed: $!" unless defined $sent && $sent > 0;
    return $sent;
}

=head2 recv_fds($sock, $count)

Receives exactly C<$count> file descriptors from C<$sock>. Returns
an arrayref of integer FD numbers. The caller owns each FD --
C<dup2()> or C<close()> as needed. Croaks on short read, missing
ancillary data, or descriptor-count mismatch.

=cut

sub recv_fds {
    my ($sock, $count) = @_;
    croak "recv_fds: socket required" unless defined $sock;
    croak "recv_fds: count required"  unless $count && $count > 0;

    my $msg = Socket::MsgHdr->new(buflen => 1, controllen => 256);
    my $rc = Socket::MsgHdr::recvmsg($sock, $msg, 0);
    croak "recvmsg failed: $!" unless defined $rc;
    croak "recvmsg returned 0 bytes; sender closed without sending fds"
        if $rc == 0;

    my @cmsg = $msg->cmsghdr;
    my @fds;
    while (my ($level, $type, $data) = splice(@cmsg, 0, 3)) {
        next unless $level == SOL_SOCKET && $type == SCM_RIGHTS;
        push @fds, unpack('i*', $data);
    }
    croak "no fds in received message" unless @fds;
    croak "expected $count fds, got " . scalar(@fds)
        unless @fds == $count;

    return \@fds;
}

1;

__END__

=pod

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

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

See L<https://dev.perl.org/licenses/>

=cut
