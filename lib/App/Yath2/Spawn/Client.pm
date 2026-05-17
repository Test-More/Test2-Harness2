package App::Yath2::Spawn::Client;
use strict;
use warnings;

our $VERSION = '2.000013';

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Spawn::Client - CLI side of the C<yath spawn> SCM_RIGHTS handover.

=head1 DESCRIPTION

Drives the C<yath spawn> command's request to a preload service: opens
a Unix-domain listener, dispatches a C<spawn_script> request through
L<Test2::Harness2::Spawn>, hands STDIN/STDOUT/STDERR to the
grandchild via L<App::Yath2::Spawn::FdPass>, and waits for the
matching C<script_exited> notification on the IPC bus.

=head1 EXPORTS

C<run_spawn>.

=cut

use Carp qw/croak/;
use File::Spec ();
use IO::Select ();
use IO::Socket::UNIX ();
use Time::HiRes qw/sleep time/;

use App::Yath2::Spawn::FdPass qw/send_fds/;

use Importer Importer => 'import';
our @EXPORT_OK = qw/run_spawn/;

my $SOCK_COUNTER = 0;

=head2 _allocate_socket_path($dir)

Returns a per-invocation Unix-socket path under C<$dir>, formed from
the CLI pid and a process-local counter. Croaks on a missing dir.

=cut

sub _allocate_socket_path {
    my ($dir) = @_;
    croak "dir required" unless defined $dir && length $dir;
    return File::Spec->catfile(
        $dir, sprintf("yath-spawn-%d-%d.sock", $$, ++$SOCK_COUNTER),
    );
}

=head2 _open_listener($path)

Creates a C<SOCK_STREAM> Unix-domain listener bound at C<$path>,
chmods it to C<0600>, and returns the socket handle.

=cut

sub _open_listener {
    my ($path) = @_;
    my $sock = IO::Socket::UNIX->new(
        Local  => $path,
        Type   => IO::Socket::UNIX::SOCK_STREAM(),
        Listen => 1,
    ) or croak "listen on $path: $!";
    chmod 0600, $path;
    return $sock;
}

=head2 run_spawn(%opts)

Runs one C<yath spawn> handover. Required options:

=over 4

=item spawn

A constructed L<Test2::Harness2::Spawn> handle for the daemon.

=item stage

The preload service / stage name to dispatch into.

=item script

Absolute path to the script to execute in the grandchild.

=back

Optional: C<argv> (arrayref), C<env> (hashref), C<cwd> (defaults to
the caller's cwd). Opens a one-shot listener under the daemon's
C<workdir/tmp>, dispatches C<spawn_script>, accepts the
grandchild's callback, sends STDIN/STDOUT/STDERR over SCM_RIGHTS,
and blocks in L</_await_script_exited> until the matching
C<script_exited> notification arrives. Returns the script's exit
code (0-255).

=cut

sub run_spawn {
    my %p = @_;
    my $spawn  = $p{spawn}  or croak "'spawn' required";
    my $stage  = $p{stage}  or croak "'stage' required";
    my $script = $p{script} or croak "'script' required";

    croak "script not readable: $script" unless -r $script;

    # Daemon's workdir/tmp is mode 0700, so the socket file inherits
    # tight permissions.
    my $tmpdir = File::Spec->catdir($spawn->workdir, 'tmp');
    croak "daemon tmpdir missing: $tmpdir" unless -d $tmpdir;

    my $sock_path = _allocate_socket_path($tmpdir);
    my $listener  = _open_listener($sock_path);

    my $resp = $spawn->spawn_script({
        stage      => $stage,
        script_abs => $script,
        argv       => $p{argv} // [],
        env        => $p{env}  // {},
        cwd        => $p{cwd}  // do { require Cwd; Cwd::getcwd() },
        sock_path  => $sock_path,
        # The CLI's IPC peer name (e.g. "harness-spawn-PID"), not the
        # service name. Harness sends script_exited back to this peer
        # over the cached connection from our sync_request above.
        notify_to  => $spawn->handle->name,
    });

    unless ($resp && $resp->{ok}) {
        close $listener;
        unlink $sock_path;
        my $err = $resp ? $resp->{error} : 'no response';
        croak "spawn_script dispatch failed: $err";
    }

    my $spawn_id = $resp->{spawn_id};

    # Accept the grandchild's connection. IO::Select gives us a
    # deadline without blocking accept() indefinitely.
    my $conn;
    my $select   = IO::Select->new($listener);
    my $deadline = time + 10;
    while (time < $deadline) {
        my $remain = $deadline - time;
        last unless $remain > 0;
        my @ready = $select->can_read($remain > 0.2 ? 0.2 : $remain);
        if (@ready) {
            $conn = $listener->accept;
            last if $conn;
        }
    }
    unless ($conn) {
        close $listener;
        unlink $sock_path;
        croak "timed out waiting for spawn grandchild to connect";
    }
    close $listener;
    unlink $sock_path;    # connection up; path no longer needed.

    # Hand STDIN/STDOUT/STDERR to the grandchild. sendmsg failures
    # (typical: grandchild died between accept and send -> EPIPE)
    # would otherwise leave us stuck in _await_script_exited.
    my $ok = eval { send_fds($conn, [ fileno(\*STDIN), fileno(\*STDOUT), fileno(\*STDERR) ]); 1 };
    my $err = $@;
    close $conn;
    croak "yath spawn: FD handover failed: $err" unless $ok;

    return _await_script_exited($spawn, $spawn_id);
}

=head2 _await_script_exited($spawn, $spawn_id)

Polls the L<Test2::Harness2::Spawn> bus handle until a
C<script_exited> message for C<$spawn_id> arrives, then returns
that script's exit code. Croaks if no message arrives within the
24-hour effectively-unbounded deadline.

=cut

sub _await_script_exited {
    my ($spawn, $spawn_id) = @_;
    my $hdl      = $spawn->handle;
    my $deadline = time + 86400;    # 24 hours; effectively unbounded.

    while (time < $deadline) {
        $hdl->poll(0.1);
        for my $msg ($hdl->messages) {
            my $c = $msg->content;
            next unless ref($c) eq 'HASH';
            next unless ($c->{kind}     // '') eq 'script_exited';
            next unless ($c->{spawn_id} // 0) == $spawn_id;
            return $c->{exit} // 0;
        }
    }

    croak "yath spawn: timeout waiting for script_exited";
}

1;

__END__

=pod

=head1 SEE ALSO

L<App::Yath2::Spawn::FdPass>, L<Test2::Harness2::Spawn>,
L<Test2::Harness2::PreloadService>.

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
