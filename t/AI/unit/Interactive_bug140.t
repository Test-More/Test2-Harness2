use v5.38;

use Test2::V0;

use POSIX ();
use Time::HiRes ();
use File::Temp qw/tempdir/;
use IO::Socket::UNIX ();

use App::Yath2;
use App::Yath2::Options::Debug ();
use Getopt::Yath::Settings;

use Test2::Harness2::Util::FdPass qw/fdpass_available/;

use Test2::Util qw/CAN_REALLY_FORK/;
skip_all "These tests require forking" if $ENV{T2_NO_FORK} || !CAN_REALLY_FORK;

$ENV{'YATH_SELF_TEST'} = 1;

# Ticket TODO-140. Three fixes to interactive mode, all exercised here:
#   (7+G4) the accept loop that the shell waits on must forward the yath child's
#          real exit status -- a signal death as 128+sig (not a masked 0/green),
#          and an ECHILD reap as a nonzero exit (not an infinite poll);
#   (77)   interactive's display/formatter overrides now run at weight 85, before
#          Display resolves renderers at 90/100, so `-q -i` renders and `-i`
#          keeps show_job_launch;
#   (G6)   every STDIN fd-pass is logged with best-effort peercred attribution
#          (the env-scrub half lives in Interactive.t).

# ---------------------------------------------------------------------------
# (7+G4) Exit-status forwarding in the command-side accept loop.
#
# _interactive_accept_loop() calls exit() with the forwarded status, so we run it
# in a forked "wrapper" (the process the shell waits on) that owns a "victim"
# child (the yath command). We build the listen socket by hand (no IO::FDPass
# needed -- these tests never pass an fd) and assert the wrapper's exit code.
# ---------------------------------------------------------------------------

sub _make_listen {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/s.sock";
    my $listen = IO::Socket::UNIX->new(
        Type   => IO::Socket::UNIX::SOCK_STREAM(),
        Local  => $path,
        Listen => 1,
    ) or die "listen socket: $!";
    return ($listen, $path);
}

# Run the real accept loop in a wrapper whose victim child is prepared by
# $victim_body. Returns the wrapper's wait status ($?). Alarm-bounded so a
# regression can never hang the suite.
sub _run_accept_loop_wrapper {
    my (%p) = @_;
    my $victim_body = $p{victim} or die "victim body required";
    my $wrapper_pre = $p{wrapper_pre} // sub { };

    my ($listen, $path) = _make_listen();

    my $wrapper = fork // die "fork wrapper: $!";
    if (!$wrapper) {
        $wrapper_pre->();
        my $victim = fork // POSIX::_exit(101);
        if (!$victim) {
            close($listen);
            $victim_body->();
            POSIX::_exit(0);    # only reached if the body did not exit/kill itself
        }
        # The command-side accept loop; it exit()s when the victim is reaped.
        App::Yath2::Options::Debug::_interactive_accept_loop($listen, $path, $victim);
        POSIX::_exit(102);      # unreachable: the loop never returns
    }

    close($listen);

    my $status;
    my $ok = eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 30;
        waitpid($wrapper, 0);
        $status = $?;
        alarm 0;
        1;
    };
    my $err = $@;
    alarm 0;

    unless ($ok) {
        kill('KILL', $wrapper);
        waitpid($wrapper, 0);
        die "accept-loop wrapper did not exit (possible hang): $err";
    }

    return $status;
}

subtest sigkill_child_forwarded_as_128_plus_sig => sub {
    # The yath child dies from SIGKILL; the wrapper must exit 137 (128+9), not a
    # masked 0. Previously `$finish->($? >> 8)` computed 9 >> 8 == 0 -> green CI.
    my $status = _run_accept_loop_wrapper(
        victim => sub {
            Time::HiRes::sleep(0.05);
            kill('KILL', $$);
            Time::HiRes::sleep(5);    # give the signal time to land
        },
    );

    is($status & 127, 0, "the wrapper itself exited normally (was not signaled)");
    is($status >> 8, 137, "SIGKILL'd interactive child forwarded as 128+9 (137)");
};

subtest echild_ignored_chld_exits_nonzero_no_hang => sub {
    # An inherited SIG_IGN on CHLD auto-reaps the child, so waitpid returns -1
    # (ECHILD) forever. The `$finish->(1) if $got < 0` guard must break the loop
    # with a nonzero exit rather than polling until Ctrl-C. Alarm-bounded above.
    my $status = _run_accept_loop_wrapper(
        wrapper_pre => sub { $SIG{CHLD} = 'IGNORE' },
        victim      => sub { Time::HiRes::sleep(0.05) },    # exits -> auto-reaped
    );

    is($status & 127, 0, "the wrapper exited normally (no hang, alarm not tripped)");
    is($status >> 8, 1, "ECHILD reap forwarded as nonzero exit (1)");
};

# ---------------------------------------------------------------------------
# (77) Display/formatter override ordering.
#
# The weight-99998 interactive post forks + requires IO::FDPass. Its guard
# `return if $RAN++` is one-shot, so priming it once (interactive OFF, so it
# returns before the fork) makes process_argv's later run short-circuit before
# forking. The weight-85 display post is unguarded and still runs -- exactly what
# we want to observe.
# ---------------------------------------------------------------------------

sub _neutralize_interactive_fork {
    my $burn = Getopt::Yath::Settings->new(debug => {interactive => 0});
    App::Yath2::Options::Debug::_post_process_interactive(undef, {settings => $burn});
}

sub _resolve_settings {
    my (@argv) = @_;
    my $settings = Getopt::Yath::Settings->new(harness => {});
    my $app = App::Yath2->new(argv => [@argv], config => {}, settings => $settings);
    my $ok  = eval { $app->process_argv; 1 };
    my $err = $@;
    die "process_argv failed for [@argv]: $err" unless $ok;
    return $settings;
}

subtest display_override_ordering => sub {
    _neutralize_interactive_fork();

    my $FMT = 'Test2::Harness2::Renderer::Formatter';

    subtest 'quiet_interactive_still_renders' => sub {
        my $s = _resolve_settings(qw/test -q -i/, '.');
        my $fmt = $s->display->renderers->{$FMT};
        ok($fmt, "-q -i keeps the Formatter renderer (prompt is visible)");
        my %args = @$fmt;
        is($args{verbose}, 1, "verbose forced on (weight 85, before Display 90/100)");
        is($args{show_job_launch}, 1, "show_job_launch set by Display's verbose>0 branch");
        is($s->display->quiet, 0, "quiet overridden to 0 for interactive");
    };

    subtest 'plain_interactive_keeps_show_job_launch' => sub {
        my $s = _resolve_settings(qw/test -i/, '.');
        my $fmt = $s->display->renderers->{$FMT};
        ok($fmt, "-i keeps the Formatter renderer");
        my %args = @$fmt;
        is($args{show_job_launch}, 1, "show_job_launch no longer frozen off pre-override");
        is($args{verbose}, 1, "verbose default-on for interactive");
    };

    subtest 'non_interactive_quiet_regression_guard' => sub {
        my $s = _resolve_settings(qw/test -q/, '.');
        ok(!$s->display->renderers->{$FMT},
            "plain -q (no -i) still deletes the Formatter renderer -- no regression");
    };
};

# ---------------------------------------------------------------------------
# (G6) Every STDIN fd-pass is logged, with best-effort SO_PEERCRED attribution.
# ---------------------------------------------------------------------------

subtest fd_pass_is_logged_with_peercred => sub {
    skip_all "fd-pass logging test needs IO::FDPass (send_fds)" unless fdpass_available();

    require Socket;
    require Test2::Harness2::Util::FdPass;

    socketpair(my $cmd_end, my $tgt_end, Socket::AF_UNIX(), Socket::SOCK_STREAM(), Socket::PF_UNSPEC())
        or die "socketpair: $!";

    # A dialer that receives the one fd, so the command-side send_fds completes.
    my $pid = fork // die "fork: $!";
    if (!$pid) {
        close($cmd_end);
        my $ok = eval { Test2::Harness2::Util::FdPass::recv_fds($tgt_end, 1); 1 };
        POSIX::_exit($ok ? 0 : 1);
    }
    close($tgt_end);

    my $warnings = warnings { App::Yath2::Options::Debug::_interactive_pass_stdin($cmd_end) };
    close($cmd_end);
    waitpid($pid, 0);
    is($? >> 8, 0, "the dialer received the passed STDIN descriptor (fd delivered)");

    my @passlines = grep { /Interactive: passed STDIN/ } @$warnings;
    is(scalar(@passlines), 1, "exactly one 'passed STDIN' log line per fd-pass");

    if ($^O eq 'linux') {
        like($passlines[0], qr/pid \d+ uid \d+/, "peercred pid/uid attributed on Linux");
    }
};

done_testing;
