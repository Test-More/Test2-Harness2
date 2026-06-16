use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;
use File::Path qw/remove_tree/;
use POSIX ();
use Time::HiRes qw/sleep time/;

use Test2::Collector qw/spawn_collector/;
use Test2::Collector::Recorder::Zstd;

use Test2::Harness2::Collector;
use Test2::Harness2::Run;
use Test2::Harness2::Util qw/runner_events_file/;

# Codex chunk-4 review #1, end-to-end regression guard.
#
# SCOPE (chunk 5g): this guards the PERSISTENT gatherer's runner-liveness path.
# The transient `yath test` path no longer uses the gatherer at all -- it
# subscribes to runner.socket and detects completion when the runner closes that
# socket, so its clients never need kill(0). The gatherer (and its kill(0,
# RUNNER_PID) liveness in Test2::Harness2::Collector::runner_exited) survives only
# for the gated persistent path (yath start / run), and this test exercises that
# surviving path directly by constructing a gatherer and calling runner_exited.
#
# The `yath` runner runs as the exec target of a non-test Test2::Collector; the
# gatherer decides the runner is alive with kill(0, RUNNER_PID), where RUNNER_PID
# is the collector PARENT pid (App::Yath2::Command::test start_runner /
# Test2::Harness2::Collector::runner_exited). When the runner dies with jobs still
# pending, the gatherer must see that promptly so it can abort the stalled jobs
# instead of spinning.
#
# A descendant that inherited the runner's STDOUT/STDERR keeps the collector's
# capture pipes open after the runner is reaped. Before Test2-Collector learned
# to finish NON-test collection at reap (rather than waiting for pipe EOF or the
# 30s orphan window), the collector parent -- and thus kill(0, RUNNER_PID) --
# could lag ~30s behind the real runner's death (or hang if the descendant kept
# writing), delaying the abort.
#
# Here the wrapped child exits immediately after forking a grandchild that holds
# the pipes open for 5s. runner_exited() must flip true well before that.

# CLEANUP is left off deliberately: spawn_collector forks, and File::Temp's
# auto-cleanup can race those forked processes and remove the dir out from under
# the collector. Remove it ourselves at the end instead.
my $RUN_ID = 'RUNNER-DEATH';
my $tmp    = tempdir();
mkdir "$tmp/$RUN_ID" or die "mkdir: $!";

my $pid = spawn_collector(
    is_test  => 0,
    name     => 'runner',
    exec     => [$^X, '-e', 'my $gc = fork // die "fork: $!"; exit 0 if $gc; sleep 5'],
    recorder => Test2::Collector::Recorder::Zstd->new(file => runner_events_file($tmp)),
);

# With the non-test drain-once behavior the collector parent exits right after
# reaping the runner, instead of lingering for the grandchild that still holds
# the capture pipes. Poll for that termination; in the real harness the IPC
# layer reaps the runner, so reap here too (a kill(0) on an un-reaped zombie
# would read as "alive" and is not what the gatherer races against). The 4s cap
# stays clear of the grandchild's 5s hold, so a regression (waiting for pipe EOF
# / the 30s orphan window) trips the guard.
my $start = time;
my $reaped;
until ($reaped) {
    last if time - $start > 4;
    $reaped = (waitpid($pid, POSIX::WNOHANG()) == $pid);
    sleep 0.05 unless $reaped;
}
my $elapsed = time - $start;

ok($reaped, "the wrapped non-test runner collector terminated after reaping the runner");
ok($elapsed < 4, sprintf("...promptly (%.2fs), not after the orphan window", $elapsed))
    or diag(sprintf("collector lingered %.2fs past the runner -- non-test drain-once not in effect", $elapsed));

# Once the collector parent is gone, the gatherer's liveness primitive must
# report the runner as exited.
my $collector = Test2::Harness2::Collector->new(
    run        => Test2::Harness2::Run->new(run_id => $RUN_ID),
    run_id     => $RUN_ID,
    workdir    => $tmp,
    runner_pid => $pid,
    action     => sub { },    # init emits a startup event; we only call runner_exited()
);
ok($collector->runner_exited, "runner_exited() reports the runner gone");

remove_tree($tmp, {safe => 1});

done_testing;
