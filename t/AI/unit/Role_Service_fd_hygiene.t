use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;
use Fcntl qw/F_GETFD FD_CLOEXEC/;
use POSIX ();

use Test2::Collector::Util::Socket qw/connect_unix/;
use Test2::Harness2::Util::IPC qw/set_cloexec/;
use Test2::Harness2::Role::Service::Connection();

# Ticket TODO-32: harness/collector sockets are FD_CLOEXEC, and the no-exec forks
# (collector parent + preload goto::file test launch) explicitly close-sweep
# every inherited connection + the listen socket so a dead collector's
# connection still EOFs promptly (ARCHITECTURE.md §5.4 "FD ownership").

# A minimal Role::Service consumer.
{

    package My::FDSvc;
    use v5.38;
    use Object::HashBase qw/<workdir <name/;
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Service';
    sub init ($self) { return }
}

# --- set_cloexec ------------------------------------------------------------
subtest set_cloexec => sub {
    pipe(my $r, my $w) or die "pipe: $!";

    ok(lives { set_cloexec($r) }, "set_cloexec lives on an open handle");
    my $flags = fcntl($r, F_GETFD, 0);
    ok($flags & FD_CLOEXEC, "FD_CLOEXEC is set after set_cloexec");

    close($r);
    close($w);
    ok(lives { set_cloexec($r) }, "set_cloexec is a no-op on a closed handle");
};

# --- the listen socket and connections are FD_CLOEXEC -----------------------
my $dir = tempdir(CLEANUP => 1);
my $svc = My::FDSvc->new(workdir => $dir, name => 'runner');
$svc->start_service;

my $listen = $svc->{service_listen};
ok($listen,                                 "service has a listen socket");
ok(fcntl($listen, F_GETFD, 0) & FD_CLOEXEC, "listen socket is FD_CLOEXEC");

# Dial in so the service accepts a connection, then confirm the accepted fd is
# FD_CLOEXEC.
my $cfh = connect_unix($svc->service_socket_path);
$cfh->blocking(0);
my $client = Test2::Harness2::Role::Service::Connection->new(fh => $cfh, outbound => 1, my_identity => 'client');
$svc->service_io for 1 .. 5;

my @accepted = values %{$svc->{service_conns}};
ok(@accepted, "service accepted the inbound connection");
ok(
    (!grep { !(fcntl($_->fh, F_GETFD, 0) & FD_CLOEXEC) } @accepted),
    "every accepted connection fd is FD_CLOEXEC",
);

# --- close_all_connections in a forked child closes inherited fds -----------
{
    my $accepted_fh = $accepted[0]->fh;

    # Fork a child that mimics the no-exec collector-parent fork: it inherits the
    # service's listen socket + the accepted connection, runs the close-sweep, and
    # reports whether each handle is now closed (fileno undef) in the child.
    pipe(my $rep_r, my $rep_w) or die "pipe: $!";
    my $pid = fork // die "fork: $!";
    if (!$pid) {
        close($rep_r);
        $svc->close_all_connections;

        my $listen_open   = defined(fileno($listen))      ? 1 : 0;
        my $accepted_open = defined(fileno($accepted_fh)) ? 1 : 0;

        print $rep_w "$listen_open,$accepted_open\n";
        close($rep_w);
        POSIX::_exit(0);
    }

    close($rep_w);
    my $line = <$rep_r> // '';
    close($rep_r);
    waitpid($pid, 0);

    chomp($line);
    is($line, "0,0", "child close_all_connections closed the inherited listen + connection fds");

    # The parent still owns its copies: the sweep in the child must not have
    # closed the parent's handles.
    ok(defined(fileno($listen)),      "parent's listen socket is still open");
    ok(defined(fileno($accepted_fh)), "parent's accepted connection is still open");
}

$svc->close_service;

done_testing;
