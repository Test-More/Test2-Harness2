package Test2::Harness2::Util::FdPass;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Errno qw/EINTR/;
use Fcntl qw/FD_CLOEXEC F_GETFD F_SETFD/;
use File::Temp qw/tempdir/;
use IO::Socket::UNIX ();

use Importer Importer => 'import';

our @EXPORT_OK = qw{
    fdpass_available
    require_fdpass
    send_fds
    recv_fds
    command_listen
    target_connect
};

# Loaded lazily and only on the spawn / interactive paths. The lean
# test/run/start path must never trigger this require, so it lives behind the
# explicit require_fdpass() guard rather than a top-of-file use.
my $IO_FDPASS_LOADED;
my $IO_FDPASS_ERROR;

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::FdPass - Pass open file descriptors between processes
over a Unix socket (C<SCM_RIGHTS>).

=head1 DESCRIPTION

A focused primitive for handing real open file descriptors -- a terminal, a
pipe end, a PTY master -- from one process to another across a connected
Unix-domain socket using C<SCM_RIGHTS> ancillary data. The receiver gets fresh
descriptor numbers that refer to the I<same> underlying open file descriptions,
so it can C<dup2> them onto its own C<STDIN> / C<STDOUT> / C<STDERR> and read or
write the sender's actual terminal directly instead of a proxied byte stream.

This is the shared mechanism under C<yath spawn> (which passes all three of the
command's standard descriptors) and interactive mode (which passes only
C<STDIN>). The choreography is always B<command-listens / target-dials>: the
process that owns the descriptors opens a listen socket, the process that needs
them connects, and the descriptors flow from the listener to the dialer.

The work is done by L<IO::FDPass>, which is an B<optional> dependency. The
module loads and the distribution installs without it; only the spawn and
interactive features need it. Nothing here loads C<IO::FDPass> at C<use> time --
call L</require_fdpass> (or any function that needs it) to trigger the load, and
get a clear, actionable error if it is absent rather than a raw require failure
deep in a worker. C<IO::FDPass> passes exactly one descriptor per call, so
L</send_fds> and L</recv_fds> loop; both ends must agree on the count.

=head1 SYNOPSIS

    use Test2::Harness2::Util::FdPass qw/command_listen target_connect send_fds recv_fds/;

    # Command side: own the descriptors, listen, pass them on.
    my ($listen, $path) = command_listen();
    # ... hand $path to the target, then:
    my $conn = $listen->accept;
    send_fds($conn, [fileno(\*STDIN), fileno(\*STDOUT), fileno(\*STDERR)]);

    # Target side: dial in, receive, install.
    my $conn = target_connect($path);
    my $fds  = recv_fds($conn, 3);
    open(\*STDIN,  '<&=', $fds->[0]) or die "dup STDIN: $!";
    open(\*STDOUT, '>&=', $fds->[1]) or die "dup STDOUT: $!";
    open(\*STDERR, '>&=', $fds->[2]) or die "dup STDERR: $!";

=head1 EXPORTS

Nothing is exported by default; request functions explicitly.

=head2 fdpass_available

    my $bool = fdpass_available();

True when L<IO::FDPass> can be loaded on this interpreter, false otherwise.
Triggers the (cached) load attempt but never throws -- use it for feature
detection before deciding to offer a descriptor-passing feature.

=cut

sub fdpass_available { __PACKAGE__->_load_io_fdpass ? 1 : 0 }

=pod

=head2 require_fdpass

    require_fdpass();
    require_fdpass($feature);

Ensure L<IO::FDPass> is loaded, or C<croak> with an actionable message naming
the feature that needs it (default C<"This feature">). Call this at the entry
point of any descriptor-passing path -- the command before it listens, the
target before it dials -- so a missing module surfaces as a clear instruction to
install it rather than a raw load failure later. Returns true on success.

=cut

sub require_fdpass {
    my ($feature) = @_;
    $feature //= 'This feature';

    return 1 if __PACKAGE__->_load_io_fdpass;

    croak "$feature requires the IO::FDPass module, which is not installed; " . "install IO::FDPass to use it ($IO_FDPASS_ERROR)";
}

=pod

=head2 send_fds

    my $sent = send_fds($sock, \@fds);

Send each open descriptor number in C<\@fds> across the connected Unix socket
C<$sock> as a sequence of C<SCM_RIGHTS> messages (one per descriptor). The
receiver must call L</recv_fds> with the same count. C<croak>s on a missing or
empty descriptor list, a closed socket, or a kernel send failure. Returns the
number of descriptors sent. Loads L<IO::FDPass> on demand (see
L</require_fdpass>).

=cut

sub send_fds {
    my ($sock, $fds) = @_;

    croak "send_fds: socket required"       unless defined $sock;
    croak "send_fds: fds arrayref required" unless ref($fds) eq 'ARRAY' && @$fds;

    require_fdpass('Descriptor passing');

    my $sockfd = fileno($sock);
    croak "send_fds: socket has no file descriptor (closed?)" unless defined $sockfd;

    for my $fd (@$fds) {
        croak "send_fds: undefined fd in list" unless defined $fd;

        my $ok;
        while (1) {
            $ok = IO::FDPass::send($sockfd, $fd);
            last if $ok;
            next if $! == EINTR;
            last;
        }

        croak "send_fds: failed to send fd $fd: $!" unless $ok;
    }

    return scalar @$fds;
}

=pod

=head2 recv_fds

    my $fds = recv_fds($sock, $count);

Receive exactly C<$count> descriptors from the connected Unix socket C<$sock>,
in the order the sender passed them. Returns an arrayref of integer descriptor
numbers; the caller owns each one and must C<dup2> / C<open '<&='> or C<close>
it. C<croak>s on a bad count, a closed socket, or a receive failure (including
the sender closing before all descriptors arrive). Loads L<IO::FDPass> on demand.

=cut

sub recv_fds {
    my ($sock, $count) = @_;

    croak "recv_fds: socket required"         unless defined $sock;
    croak "recv_fds: positive count required" unless defined $count && $count > 0;

    require_fdpass('Descriptor passing');

    my $sockfd = fileno($sock);
    croak "recv_fds: socket has no file descriptor (closed?)" unless defined $sockfd;

    my @fds;
    for my $i (1 .. $count) {
        my $fd;
        while (1) {
            $fd = IO::FDPass::recv($sockfd);
            last if defined $fd && $fd >= 0;
            next if $! == EINTR;
            last;
        }

        croak "recv_fds: failed to receive fd $i of $count: " . ($! ? "$!" : "sender closed before sending all fds")
            unless defined $fd && $fd >= 0;

        push @fds => $fd;
    }

    return \@fds;
}

=pod

=head2 command_listen

    my ($listen, $path) = command_listen();
    my ($listen, $path) = command_listen(%params);

Open the command-side listen socket the target dials back to. Creates a private
C<0700> temporary directory (via L<File::Temp>, kept short to stay under the
C<sun_path> length cap) and binds a C<0600> C<SOCK_STREAM> Unix socket inside it
with a random name. The listen handle is set close-on-exec so a forked child
does not inherit it. Returns the L<IO::Socket::UNIX> listen handle and its
filesystem path; the caller hands the path to the target and C<accept>s the
dial-back. C<die>s on failure. Accepts C<dir> to override the temp-directory
parent.

=cut

sub command_listen {
    my (%params) = @_;

    require_fdpass('Descriptor passing');

    my $tmp = tempdir('t2fdpassXXXX', TMPDIR => 1, CLEANUP => 1, ($params{dir} ? (DIR => $params{dir}) : ()));
    chmod(0700, $tmp) or die "Failed to chmod listen dir '$tmp': $!";

    # A random leaf under the private 0700 dir; the directory perms are the real
    # access control, the random name just avoids collisions across calls.
    my $path = "$tmp/s." . sprintf('%04x%04x', int(rand(0xffff)), int(rand(0xffff)));

    my $listen = IO::Socket::UNIX->new(
        Type   => IO::Socket::UNIX::SOCK_STREAM(),
        Local  => $path,
        Listen => 1,
    ) or die "Failed to open fd-pass listen socket '$path': $!";

    chmod(0600, $path) or die "Failed to chmod listen socket '$path': $!";

    __PACKAGE__->_set_cloexec($listen);

    return ($listen, $path);
}

=pod

=head2 target_connect

    my $sock = target_connect($path);

Dial the command's listen socket at C<$path> (the value L</command_listen>
returned) and return the connected L<IO::Socket::UNIX> handle, ready for
L</recv_fds>. C<croak>s if the socket is absent or not accepting.

=cut

sub target_connect {
    my ($path) = @_;

    croak "target_connect: path required" unless defined $path && length $path;

    require_fdpass('Descriptor passing');

    my $sock = IO::Socket::UNIX->new(
        Type => IO::Socket::UNIX::SOCK_STREAM(),
        Peer => $path,
    ) or croak "Failed to connect to fd-pass socket '$path': $!";

    return $sock;
}

=pod

=head1 PRIVATE METHODS

=head2 _load_io_fdpass

    my $bool = $class->_load_io_fdpass();

Attempt the cached, eval-guarded C<require IO::FDPass>. Returns true once it has
loaded, false (with the failure recorded for L</require_fdpass>) when it cannot.
Never throws.

=cut

sub _load_io_fdpass {
    my ($class) = @_;

    return $IO_FDPASS_LOADED if defined $IO_FDPASS_LOADED;

    my $ok = eval { require IO::FDPass; 1 };
    if ($ok) {
        $IO_FDPASS_LOADED = 1;
    }
    else {
        $IO_FDPASS_LOADED = 0;
        $IO_FDPASS_ERROR  = $@ || 'unknown error';
        chomp($IO_FDPASS_ERROR);
    }

    return $IO_FDPASS_LOADED;
}

=pod

=head2 _set_cloexec

    $class->_set_cloexec($fh);

Set the close-on-exec flag on C<$fh> so a later C<exec> in a forked child does
not leak the descriptor. C<die>s if the flag cannot be read or set.

=cut

sub _set_cloexec {
    my ($class, $fh) = @_;

    my $flags = fcntl($fh, F_GETFD, 0);
    die "Failed to read fd flags: $!" unless defined $flags;

    fcntl($fh, F_SETFD, $flags | FD_CLOEXEC)
        or die "Failed to set close-on-exec: $!";

    return 1;
}

1;

__END__

=pod

=head1 PORTABILITY

C<SCM_RIGHTS> descriptor passing works on every real Unix (Linux, the BSDs,
macOS, Solaris) -- the same footprint the harness already assumes. The only
extra requirement is L<IO::FDPass>, which ships XS but is optional: this module
loads everywhere, and only the spawn / interactive features error (with an
actionable message) when it is missing.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

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

See L<http://dev.perl.org/licenses/>

=cut
