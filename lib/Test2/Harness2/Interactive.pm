package Test2::Harness2::Interactive;
use v5.38;

our $VERSION = '2.000000';

use Importer ();

our @EXPORT_OK = qw{
    interactive_socket
    connect_stdin
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Interactive - Receive the interactive command's real STDIN
descriptor over a Unix socket.

=head1 DESCRIPTION

Interactive mode (C<yath test --interactive>) shares B<only> the command's
C<STDIN> with the one test running at a time, so prompts, C<perl -d>, and
C<$DB::single> read the user's real terminal. C<STDOUT> / C<STDERR> stay with the
collector and render through the normal events path.

The command opens a listen socket and advertises its path in
C<$ENV{YATH_INTERACTIVE}>; the test process dials in, receives the command's real
C<STDIN> descriptor (one fd, via C<SCM_RIGHTS>), and C<dup2>s it onto fd C<0>. The
descriptor is the terminal itself -- no proxied byte stream -- so single
keystrokes and raw mode work.

There are two launch paths, both routed through L</connect_stdin>:

=over 4

=item Preload path

The C<goto::file> filter in L<Test2::Harness2::Runner::JobLauncher> calls
L</connect_stdin> in-process (no exec) once, right where the 1.0 FIFO re-open used
to live.

=item No-preload path

The collected test is exec'd as a clean C<perl>. The launcher injects
C<-MTest2::Harness2::Interactive> into that command line, so this module's
C<import> runs at startup -- before the test body -- and, when
C<$ENV{YATH_INTERACTIVE}> is set, performs the same connect / receive / C<dup2>.

=back

=head1 LIMITATIONS

Passing the terminal descriptor gives correct C<isatty> / termios / raw-mode
reads, but not a controlling terminal: the test does not own the tty's foreground
process group, so C</dev/tty>, terminal-generated C<SIGINT> / C<SIGTSTP> /
C<SIGWINCH>, and job control are not delivered by the kernel and would need
explicit forwarding. A test that leaves the terminal in raw mode on an abrupt
death may require the user to run C<reset>.

=head1 EXPORTS

Nothing is exported by default; request functions explicitly. The C<import>
method doubles as the no-preload startup hook (it connects STDIN, then performs
the normal import).

=head2 interactive_socket

    my $path = interactive_socket();

The interactive listen-socket path the command advertised, or C<undef> when not
running interactively. A thin reader for C<$ENV{YATH_INTERACTIVE}>.

=cut

sub interactive_socket {
    my $path = $ENV{YATH_INTERACTIVE};
    return undef unless defined $path && length $path;
    return $path;
}

=pod

=head2 connect_stdin

    connect_stdin();
    connect_stdin($path);

Dial the interactive command's listen socket, receive its real C<STDIN>
descriptor over C<SCM_RIGHTS>, and install it onto fd C<0> (and re-bless Perl's
C<STDIN> onto the new descriptor). C<$path> defaults to
C<$ENV{YATH_INTERACTIVE}>; with no path and none in the environment this is a
no-op (returns false). Returns true once C<STDIN> has been installed.

Requires L<IO::FDPass>; if it is absent this C<die>s with an actionable message
(via L<Test2::Harness2::Util::FdPass/require_fdpass>) rather than crashing
obscurely after the connect. This is the single point both interactive launch
paths route through.

=cut

sub connect_stdin {
    my ($path) = @_;
    $path //= interactive_socket();
    return 0 unless defined $path && length $path;

    require POSIX;
    require Test2::Harness2::Util::FdPass;
    Test2::Harness2::Util::FdPass::require_fdpass('Interactive mode');

    my $sock = Test2::Harness2::Util::FdPass::target_connect($path);
    my $fds  = Test2::Harness2::Util::FdPass::recv_fds($sock, 1);
    my $in   = $fds->[0];

    POSIX::dup2($in, 0) // die "Could not dup2 interactive STDIN onto fd 0: $!";
    POSIX::close($in) if $in != 0;

    # Re-bless the Perl STDIN handle onto the dup2'd descriptor so reads from
    # STDIN follow the command's real terminal.
    open(\*STDIN, '<&=', 0) or die "Could not reopen STDIN: $!";

    # The dial-back connection has done its job (the fd now lives on fd 0); the
    # socket itself carries no further data for interactive mode.
    close($sock);

    return 1;
}

=pod

=head1 PRIVATE METHODS

=head2 import

    use Test2::Harness2::Interactive;

The no-preload startup hook. When the test was exec'd with
C<-MTest2::Harness2::Interactive> and C<$ENV{YATH_INTERACTIVE}> is set, this
runs L</connect_stdin> before the test body reads C<STDIN>, then performs the
normal L<Importer>-style import of any requested C<@EXPORT_OK> functions. A
failure to receive the descriptor is fatal (the test would otherwise read the
wrong C<STDIN>) and surfaces through the collector as a job failure.

=cut

sub import {
    my $class = shift;

    connect_stdin() if defined $ENV{YATH_INTERACTIVE} && length $ENV{YATH_INTERACTIVE};

    my $caller = caller;
    Importer->import_into($class, $caller, @_);

    return;
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

See L<http://dev.perl.org/licenses/>

=cut
