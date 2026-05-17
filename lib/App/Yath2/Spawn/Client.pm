package App::Yath2::Spawn::Client;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use File::Spec ();
use IO::Select ();
use IO::Socket::UNIX ();
use Time::HiRes qw/sleep time/;

use App::Yath2::Spawn::FdPass qw/send_fds/;

use Importer Importer => 'import';
our @EXPORT_OK = qw/run_spawn/;

my $SOCK_COUNTER = 0;

sub _allocate_socket_path {
    my ($dir) = @_;
    croak "dir required" unless defined $dir && length $dir;
    return File::Spec->catfile(
        $dir, sprintf("yath-spawn-%d-%d.sock", $$, ++$SOCK_COUNTER),
    );
}

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

# Function too long, break it up
# run_spawn(%opts):
#   spawn   => Test2::Harness2::Spawn instance (already constructed)
#   stage   => stage name string
#   script  => absolute path to script
#   argv    => arrayref of args
#   env     => hashref of env vars
#   cwd     => caller's absolute cwd
# Returns: exit code (0..255) suitable for `exit $code`.
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

    # Accept the grandchild's connection. Use IO::Select so we can
    # apply a deadline without blocking accept() indefinitely.
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

    # Send STDIN/STDOUT/STDERR to the grandchild. If sendmsg fails
    # (typical: grandchild died between accept and send -> EPIPE) the
    # script will never run; surface the underlying error rather than
    # leaving the caller blocked in _await_script_exited.
    my $ok = eval { send_fds($conn, [ fileno(\*STDIN), fileno(\*STDOUT), fileno(\*STDERR) ]); 1 };
    my $err = $@;
    close $conn;
    croak "yath spawn: FD handover failed: $err" unless $ok;

    # Wait for the script_exited notification on the IPC bus.
    my $exit = _await_script_exited($spawn, $spawn_id);

    return $exit;
}

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
