use Test2::V0;
use v5.38;

# Ticket TODO-139 (finding 6+G2): App::Yath2::Command::spawn::bridge_io must NOT report a
# clean exit 0 when the supervisor's control channel closes WITHOUT an exit_status
# frame (an OOM/crash between hello and exit_status leaves the setsid'd script running
# detached). This drives the REAL bridge_io against a forked "supervisor" that dials
# back over a real command_listen socket, does the SCM_RIGHTS pass, then either
# reports a status (healthy) or vanishes (no exit_status).

use POSIX ();

use Test2::Util qw/CAN_REALLY_FORK/;
skip_all "This test requires forking" if $ENV{T2_NO_FORK} || !CAN_REALLY_FORK;
skip_all "This feature requires IO::FDPass" unless eval { require IO::FDPass; 1 };

use Test2::Harness2::Util::FdPass qw/command_listen target_connect recv_fds/;
use Test2::Harness2::Util::FdPass::Control;

require App::Yath2::Command::spawn;

# Run the real bridge_io in this process while a forked supervisor plays the other
# side. $sup_body->($ctl) decides what the supervisor sends. Returns the parsed exit
# hashref bridge_io produced and whatever it wrote to STDERR (the vanish message).
sub drive_bridge_io {
    my ($sup_body) = @_;

    my ($listen, $path) = command_listen();

    my $pid = fork // die "fork failed: $!";
    if (!$pid) {
        # Supervisor side.
        eval { close($listen); 1 };
        my $ok = eval {
            my $sock = target_connect($path);
            my $fds  = recv_fds($sock, 3);              # drain the SCM_RIGHTS pass
            POSIX::close($_) for grep { $_ > 2 } @$fds; # drop received dups we don't need
            my $ctl = Test2::Harness2::Util::FdPass::Control->new(fh => $sock);
            $sup_body->($ctl);
            1;
        };
        POSIX::_exit($ok ? 0 : 1);
    }

    # Capture STDERR at the fd level so bridge_io's fileno(\*STDERR) stays a real fd
    # for the descriptor pass while its vanish print is still captured. STDERR is
    # unbuffered, so each print is a write(2) to fd 2 -- redirect fd 2 to a temp file.
    open(my $errfh, '+>', undef) or die "temp stderr: $!";
    my $save_err = POSIX::dup(2);
    POSIX::dup2(fileno($errfh), 2);

    my $exit;
    {
        # Restore %SIG afterward: bridge_io installs/clears signal-forwarding handlers.
        local %SIG = %SIG;
        $exit = App::Yath2::Command::spawn::bridge_io(bless({}, 'App::Yath2::Command::spawn'), $listen);
    }

    POSIX::dup2($save_err, 2);
    POSIX::close($save_err);

    seek($errfh, 0, 0);
    my $stderr = do { local $/; <$errfh> } // '';

    waitpid($pid, 0);

    return ($exit, $stderr);
}

subtest healthy_exit_status_reported => sub {
    my ($exit, $stderr) = drive_bridge_io(sub {
        my ($ctl) = @_;
        $ctl->send_hello($$);
        $ctl->send_exit_status(3 << 8);    # exit code 3, no signal
        $ctl->close;
    });

    is($exit->{err}, 3,   "bridge_io reported the real exit code");
    is($exit->{sig}, 0,   "no signal on a clean exit");
    unlike($stderr, qr/vanished/, "no vanish message on a healthy exit");
};

subtest vanish_on_frameless_eof => sub {
    my ($exit, $stderr) = drive_bridge_io(sub {
        my ($ctl) = @_;
        $ctl->send_hello($$);
        $ctl->close;    # crash/OOM: no exit_status frame ever sent
    });

    is($exit->{err}, 255, "bridge_io exits non-zero (255) when the supervisor vanished");
    is($exit->{sig}, 0,   "vanish is not reported as a signal death");
    like(
        $stderr,
        qr/spawn supervisor vanished before reporting an exit status/,
        "bridge_io printed the vanish diagnostic to STDERR",
    );
};

done_testing;
