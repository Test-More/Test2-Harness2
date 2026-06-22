use Test2::V0;
# HARNESS-DURATION-LONG

# Behavioral test for the ARCHITECTURE.md §4.1 invariant: a collector spawned
# under the runner watches the runner's pid and self-terminates if the runner
# dies. We start a persistent runner, run a test that records its pid and sleeps,
# then SIGKILL the runner (which does NOT signal its children). The job's collector
# must notice the runner is gone, kill the test process, and exit -- so no orphaned
# test process survives a crashed runner.
#
# Drives yath directly (not via App::Yath2::Tester) so we control
# YATH_PERSISTENCE_DIR and can read the persistent runner's pfile/pid.

use File::Temp qw/tempdir/;
use File::Spec ();
use File::Path qw/remove_tree/;
use POSIX qw/WNOHANG/;
use Time::HiRes qw/sleep time/;

use Test2::Util qw/CAN_REALLY_FORK/;

use App::Yath2;
use App::Yath2::Util qw/find_yath/;
use Test2::Harness2::Util::IPC qw/run_cmd/;

skip_all "Cannot fork, skipping runner-death test" unless CAN_REALLY_FORK;
skip_all "This test requires forking" if $ENV{T2_NO_FORK};
skip_all "Not run under automated testing" if $ENV{AUTOMATED_TESTING};

my $tdir = __FILE__;
$tdir =~ s{\.t$}{}g;
$tdir =~ s{^\./}{};

my $pdir    = tempdir(CLEANUP => 1);
my $pidfile = File::Spec->catfile(tempdir(CLEANUP => 1), 'test.pid');
my $outdir  = tempdir(CLEANUP => 1);

local $ENV{YATH_PERSISTENCE_DIR} = $pdir;
local $ENV{KILL_PIDFILE}         = $pidfile;

my $yath    = find_yath;
my $apppath = App::Yath2->app_path;
my @base    = ($^X, '-Ilib', $yath, "-D$apppath");

my ($runner_pid, $run_pid, $test_pid, $start_pid, $runner_dir);

my $cleanup = sub {
    kill('KILL', $test_pid)   if $test_pid   && kill(0, $test_pid);
    kill('KILL', $runner_pid) if $runner_pid && kill(0, $runner_pid);
    for my $p (grep { $_ } $run_pid, $start_pid) {
        kill('KILL', $p) if kill(0, $p);
        waitpid($p, 0);
    }
    # The SIGKILL'd runner cannot clean its own workdir; remove it.
    remove_tree($runner_dir, {safe => 1}) if $runner_dir && -d $runner_dir;
};

sub spawn_to {
    my ($file, @cmd) = @_;
    open(my $fh, '>', $file) or die "open $file: $!";
    return run_cmd(no_set_pgrp => 1, stdout => $fh, stderr => $fh, command => [@cmd]);
}

my $ok = eval {
    # 1. Start a persistent runner (no preloads -> the runner forks the job's
    #    collector directly on the no-preload path). `yath start` spawns the runner
    #    and returns, so wait for it to finish before reading the pfile.
    $start_pid = spawn_to(File::Spec->catfile($outdir, 'start.out'), @base, 'start');
    waitpid($start_pid, 0);
    $start_pid = undef;

    # 2. Wait for the discovery symlink to appear, follow it to the workdir, and
    #    read the runner pid from the workdir PID file.
    my $link;
    for (1 .. 600) {
        opendir(my $dh, $pdir) or die "opendir $pdir: $!";
        my ($pname) = grep { /yath-runner\.sock\z/ } readdir($dh);
        closedir($dh);
        if (defined $pname) { $link = File::Spec->catfile($pdir, $pname); last }
        sleep 0.1;
    }
    ok($link && -l $link, "persistent runner published its discovery symlink") or die "no symlink under $pdir\n";

    my $target = readlink($link) or die "could not readlink $link: $!";
    my ($vol, $dir, undef) = File::Spec->splitpath($target);
    $runner_dir = File::Spec->catpath($vol, $dir, '');
    $runner_dir =~ s{/\z}{};

    my $pidfile = File::Spec->catfile($runner_dir, 'PID');
    open(my $pf, '<', $pidfile) or die "open PID file: $!";
    $runner_pid = <$pf>;
    close($pf);
    chomp($runner_pid) if defined $runner_pid;
    ok($runner_pid && kill(0, $runner_pid), "persistent runner is alive (pid $runner_pid)")
        or die "runner pid not alive\n";

    # 3. Background a `yath run` of the long-sleeping test.
    $run_pid = spawn_to(File::Spec->catfile($outdir, 'run.out'), @base, 'run', $tdir, '--ext=tx');
    ok($run_pid, "backgrounded `yath run` (pid $run_pid)") or die "no run pid\n";

    # 4. Wait for the test process to come up and record its pid.
    for (1 .. 600) {
        last if -s $pidfile;
        die "the backgrounded `yath run` exited before the test started\n"
            if waitpid($run_pid, WNOHANG) == $run_pid;
        sleep 0.1;
    }
    ok(-s $pidfile, "test process started and wrote its pidfile") or die "no test pidfile\n";

    open(my $tf, '<', $pidfile) or die "open test pidfile: $!";
    chomp($test_pid = <$tf>);
    close($tf);
    ok($test_pid && kill(0, $test_pid), "test process is alive (pid $test_pid)")
        or die "test pid not alive\n";

    # 5. SIGKILL the runner. This does NOT signal the test process or its collector
    #    -- only the collector's watch_parent_pid can take them down.
    ok(kill('KILL', $runner_pid), "SIGKILL'd the runner");

    # 6. The job collector watches the runner pid; once it sees the runner gone it
    #    kills the test and exits. Assert the test process dies on its own.
    my $died     = 0;
    my $deadline = time + 30;
    while (time < $deadline) {
        unless (kill(0, $test_pid)) { $died = 1; last }
        sleep 0.1;
    }
    unless ($died) {
        diag("runner still alive? " . (kill(0, $runner_pid) ? 'YES' : 'no'));
        diag("test_pid=$test_pid runner_pid=$runner_pid");
        if (open(my $rh, '<', File::Spec->catfile($outdir, 'run.out'))) {
            my @l = <$rh>; close($rh);
            diag("run.out tail: " . join('', @l[-6 .. -1]));
        }
    }
    ok($died, "test process self-terminated after the runner was SIGKILL'd (no orphan)");

    1;
};
my $err = $@;

$cleanup->();

ok($ok, "test ran without a fatal error") or diag($err);

done_testing;
