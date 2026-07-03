use Test2::V0;
use Test2::Tools::Spec;
# HARNESS-DURATION-SHORT

# Ticket #120: `yath watch` (and, for hygiene, `yath stop`/`yath kill`) must
# detect a persistent runner via the discovery SYMLINK, which points at the
# runner's unix SOCKET -- NOT via `-f` on that symlink.
#
# The pfile "path" is a symlink whose target is `runner.socket`, a unix socket.
# `-f` follows the symlink and asks "is the target a regular file?" -- for a
# socket the answer is ALWAYS false, so watch.pm's old
# `return 1 unless -f $self->pfile->path` fired the exit on the very first idle
# tick, making it impossible to monitor an idle runner between runs.
#
# The fix keys the "runner still here" test on `-l $link && $disco->resolves`
# (the link still exists AND still resolves to a live socket). This test proves
# that predicate against a REAL bound socket + symlink fixture across the live
# and gone states, and pins the root cause (`-f` is always false).

use File::Temp qw/tempdir/;
use File::Spec;

use Test2::Collector::Util::Socket qw/open_unix_listen/;
use Test2::Harness2::Util qw/clean_path/;

use App::Yath2::Discovery;

# Stand up a runner-style workdir: a bound `runner.socket` plus a PID file, and a
# separate symlink pointing at that socket (the discovery link). Returns
# ($workdir, $link, $listen) -- keep $listen in scope so the socket stays bound.
sub make_fixture {
    my (%params) = @_;
    my $workdir = clean_path(tempdir(CLEANUP => 1));

    my $sock_path = File::Spec->catfile($workdir, 'runner.socket');
    my $listen    = open_unix_listen($sock_path);

    my $pidfile = File::Spec->catfile($workdir, 'PID');
    open(my $fh, '>', $pidfile) or die "Could not write PID file: $!";
    print $fh ($params{pid} // $$);
    close($fh);

    my $link = File::Spec->catfile($workdir, 'discovery.link');
    symlink($sock_path, $link) or die "symlink failed: $!";

    return ($workdir, $link, $listen);
}

# A pid guaranteed dead (fork/exit/reap) so kill(0) reports ESRCH: a runner that
# has fully stopped.
sub dead_pid {
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if (!$pid) { exit 0 }
    waitpid($pid, 0);
    return $pid;
}

tests live_runner_stays_attached => sub {
    my ($workdir, $link, $listen) = make_fixture();

    # Root cause: the link IS a symlink and DOES exist, but -f is false because it
    # resolves to a socket (not a regular file). This is exactly what broke watch.
    ok(-l $link, "the discovery path is a symlink");
    ok(-e $link, "the discovery path exists (follows to the socket)");
    ok(!-f $link, "-f is FALSE on a symlink-to-socket -- the #120 root cause");

    my $disco = App::Yath2::Discovery->new(link => $link);
    ok($disco->resolves, "Discovery::resolves is TRUE for a live socket");

    # The predicate the fixed watch/stop/kill code keys on: stay attached while
    # the link exists AND resolves. The old `-f` predicate would have bailed here.
    ok((-l $link && $disco->resolves), "new predicate => runner still here (stay attached)");
    ok(!(-f $link), "old `-f` predicate => would have exited immediately (the bug)");
};

tests stopped_runner_exits => sub {
    my ($workdir, $link, $listen) = make_fixture(pid => dead_pid());

    my $disco = App::Yath2::Discovery->new(link => $link);
    ok($disco->resolves, "resolves TRUE while the socket is still bound");
    ok((-l $link && $disco->resolves), "predicate holds while live");

    # The runner stops: its socket stops accepting and is unlinked, its pid is
    # dead. A FRESH probe must now report not-live so the done_check exits.
    close($listen);
    unlink(File::Spec->catfile($workdir, 'runner.socket'));

    ok(!$disco->resolves, "resolves FALSE once the socket is gone and the pid is dead");
    ok(!(-l $link && $disco->resolves), "predicate FALSE => watch/stop/kill exit (runner gone)");

    # -l alone still catches a fully-removed discovery link (the other exit arm).
    ok(-l $link, "the stale link is still present (a dangling link)");
    unlink($link);
    ok(!(-l $link), "-l FALSE once the link itself is removed => exit");
};

tests f_never_detects_a_live_socket => sub {
    # Belt-and-suspenders: across BOTH states, -f is never a correct signal.
    my ($workdir, $link, $listen) = make_fixture();
    ok(!-f $link, "-f false while the runner is LIVE (would falsely exit)");

    close($listen);
    unlink(File::Spec->catfile($workdir, 'runner.socket'));
    ok(!-f $link, "-f false while the runner is GONE (indistinguishable -- useless)");
};

done_testing;
