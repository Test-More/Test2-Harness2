use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;
use File::Path qw/remove_tree/;
use POSIX ();
use Time::HiRes qw/sleep time/;

use Test2::Collector qw/spawn_collector/;
use Test2::Collector::Recorder::Zstd;

use Test2::Harness2::Util qw/runner_events_file/;

# Codex chunk-4 review #1, end-to-end regression guard (re-expressed for chunk
# 6.1-3, gatherer deleted).
#
# SCOPE: the `yath` runner runs as the exec target of a non-test
# Test2::Collector. The yath-side gatherer that once decided runner liveness with
# kill(0, RUNNER_PID) has been deleted: clients now detect the runner via the
# socket (the runner closes runner.socket when the run is done, and a connect /
# EOF on that socket is the liveness/completion signal -- see the subscription
# render path exercised by t/integration/test.t and concurrency.t).
#
# What still matters for that socket-liveness model -- and what this test guards
# -- is that the non-test collector wrapping the runner TERMINATES PROMPTLY once
# the runner is reaped, instead of lingering for the orphan window. If it lagged,
# the runner.socket would stay bound and the command would not see completion.
#
# A descendant that inherited the runner's STDOUT/STDERR keeps the collector's
# capture pipes open after the runner is reaped. Before Test2-Collector learned
# to finish NON-test collection at reap (rather than waiting for pipe EOF or the
# 30s orphan window), the collector parent could lag ~30s behind the real
# runner's death (or hang if the descendant kept writing).
#
# Here the wrapped child exits immediately after forking a grandchild that holds
# the pipes open for 5s. The collector parent must terminate well before that.

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
# the capture pipes. Poll for that termination; in the real harness the IPC layer
# reaps the runner, so reap here too. The 4s cap stays clear of the grandchild's
# 5s hold, so a regression (waiting for pipe EOF / the 30s orphan window) trips
# the guard.
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

remove_tree($tmp, {safe => 1});

done_testing;
