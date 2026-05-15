package App::Yath2::Spawn::FdPass;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use Socket qw/SOL_SOCKET SCM_RIGHTS/;
use Socket::MsgHdr ();
use Importer Importer => 'import';

our @EXPORT_OK = qw/send_fds recv_fds/;

# Send a list of file descriptors over a Unix-domain socket as a
# SCM_RIGHTS ancillary message. The kernel duplicates each FD into
# the receiver's FD table; the receiver gets fresh FD numbers pointing
# at the same underlying file objects.
#
# A single byte of payload (\0) accompanies the ancillary data — most
# kernels refuse to deliver an SCM_RIGHTS message with zero-length
# normal data, so we always include a placeholder.
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

# Receive $count file descriptors from a Unix-domain socket. Returns
# an arrayref of integer FD numbers; the caller is responsible for
# closing them (or dup2'ing them, then closing).
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
