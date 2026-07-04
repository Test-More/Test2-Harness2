use Test2::V0;
# Regression for ticket TODO-155: App::Yath2::Tester's timeout-recovery reap must not
# hang on a child that ignores/absorbs SIGTERM. _terminate_timed_out_child sends
# TERM, waits a short grace window, then escalates to SIGKILL so a wedged runner
# can never turn a timeout into an infinite hang of the calling test file.

use POSIX ();
use Time::HiRes ();

use App::Yath2::Tester ();

# Fork a child, install a TERM disposition, tell the parent it is ready, then
# sleep well past the grace window. Inline (no exec) so the disposition is in
# place before we announce readiness -- no startup race.
sub spawn_child {
    my ($term_disp) = @_;

    pipe(my $rdy_r, my $rdy_w) or die "pipe: $!";

    my $pid = fork();
    die "fork failed: $!" unless defined $pid;

    unless ($pid) {
        # child
        $SIG{TERM} = $term_disp;
        close($rdy_r);
        syswrite($rdy_w, 'R');
        close($rdy_w);
        Time::HiRes::sleep(60);
        POSIX::_exit(0);
    }

    close($rdy_w);
    my $buf = '';
    sysread($rdy_r, $buf, 1);    # block until the child installed its handler
    close($rdy_r);

    return $pid;
}

subtest term_respecting_child_reaped_via_term => sub {
    my $pid = spawn_child('DEFAULT');

    my $start = Time::HiRes::time();
    my $exit = App::Yath2::Tester::_terminate_timed_out_child($pid, grace => 3);
    my $elapsed = Time::HiRes::time() - $start;

    ok($elapsed < 3, "reaped promptly via TERM, before grace expired (${elapsed}s)");
    is($exit & 127, POSIX::SIGTERM(), "child terminated by SIGTERM");
    is(waitpid($pid, POSIX::WNOHANG()), -1, "child fully reaped (no zombie)");
};

subtest term_ignoring_child_escalates_to_kill => sub {
    my $pid = spawn_child('IGNORE');

    my $start = Time::HiRes::time();
    # Short grace so the test does not linger; KILL fires right after it lapses.
    my $exit = App::Yath2::Tester::_terminate_timed_out_child($pid, grace => 1);
    my $elapsed = Time::HiRes::time() - $start;

    ok($elapsed < 5, "reaped within grace+KILL window, did not hang (${elapsed}s)");
    ok($elapsed >= 1, "waited the full grace window before escalating (${elapsed}s)");
    is($exit & 127, POSIX::SIGKILL(), "TERM-ignoring child escalated to SIGKILL");
    is(waitpid($pid, POSIX::WNOHANG()), -1, "child fully reaped (no zombie)");
};

done_testing;
