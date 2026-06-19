use Test2::V0;
# HARNESS-DURATION-LONG

# Chunk 19.5 (§6.10): the preload-root PROCESS crashing mid-run, with live stages.
# This is the case that has no in-process user hook to trigger (named stages fork;
# nothing user-controlled runs in the preload-root after startup), so we trigger it
# with a real external SIGKILL -- made reliable by RootPidPreload, which records the
# preload-root's own pid (it loads IN the preload-root, before stages fork) to a
# pidfile.
#
# Orchestration: a persistent runner with the preload, -j1 so a_inflight.tx runs
# while z_pending.tx waits. Once a_inflight is in flight (it records its pid and
# blocks on a go-file), we SIGKILL the preload-root, then release a_inflight. The
# runner must: (1) let the in-flight job finish -- it runs in a forked stage whose
# collector watches the REAL runner, not the dead preload-root; (2) detect the dead
# preload-root, respawn a fresh incarnation, and dispatch the still-pending
# z_pending.tx to it. Both tests pass and `yath run` exits 0.

use File::Temp qw/tempdir/;
use File::Spec ();
use File::Path qw/remove_tree/;
use POSIX qw/WNOHANG/;
use Time::HiRes qw/sleep time/;

use Test2::Util qw/CAN_REALLY_FORK/;

use App::Yath2;
use App::Yath2::Util qw/find_yath/;
use Test2::Harness2::Util::IPC qw/run_cmd/;
use Test2::Harness2::Util::JSON qw/decode_json/;

skip_all "Cannot fork, skipping preload-root kill test" unless CAN_REALLY_FORK;
skip_all "This test requires forking" if $ENV{T2_NO_FORK};
skip_all "Not run under automated testing" if $ENV{AUTOMATED_TESTING};

my $tdir = __FILE__;
$tdir =~ s{\.t$}{}g;
$tdir =~ s{^\./}{};
my $lib = File::Spec->catdir($tdir, 'lib');

my $pdir          = tempdir(CLEANUP => 1);
my $scratch       = tempdir(CLEANUP => 1);
my $root_pidfile  = File::Spec->catfile($scratch, 'preload-root.pid');
my $inflight_pid  = File::Spec->catfile($scratch, 'inflight.pid');
my $gofile        = File::Spec->catfile($scratch, 'go');
my $outdir        = tempdir(CLEANUP => 1);

local $ENV{YATH_PERSISTENCE_DIR}      = $pdir;
local $ENV{T2H_PRELOAD_ROOT_PIDFILE}  = $root_pidfile;
local $ENV{T2H_INFLIGHT_PIDFILE}      = $inflight_pid;
local $ENV{T2H_INFLIGHT_GOFILE}       = $gofile;

my $yath    = find_yath;
my $apppath = App::Yath2->app_path;
# -D dev-libs propagate to the spawned runner + preload-root (so they can load the
# preload); -D goes before the command. App::Yath2's own dev path + our preload lib.
my @base    = ($^X, '-Ilib', $yath, "-D$apppath", "-D$lib");

my ($runner_pid, $run_pid, $start_pid, $runner_dir, $root_pid);

my $cleanup = sub {
    kill('KILL', $root_pid)   if $root_pid   && kill(0, $root_pid);
    kill('KILL', $runner_pid) if $runner_pid && kill(0, $runner_pid);
    for my $p (grep { $_ } $run_pid, $start_pid) {
        kill('KILL', $p) if kill(0, $p);
        waitpid($p, 0);
    }
    remove_tree($runner_dir, {safe => 1}) if $runner_dir && -d $runner_dir;
};

sub spawn_to {
    my ($file, @cmd) = @_;
    open(my $fh, '>', $file) or die "open $file: $!";
    return run_cmd(no_set_pgrp => 1, stdout => $fh, stderr => $fh, command => [@cmd]);
}

my $ok = eval {
    # 1. Start a persistent runner with the preload (spawns a preload-root).
    $start_pid = spawn_to(File::Spec->catfile($outdir, 'start.out'), @base, 'start', '-PRootPidPreload', '-j1');
    waitpid($start_pid, 0);
    $start_pid = undef;

    # 2. Read the runner pid from the pfile.
    my $pfile;
    for (1 .. 600) {
        opendir(my $dh, $pdir) or die "opendir $pdir: $!";
        my ($pname) = grep { /yath-persist\.json\z/ } readdir($dh);
        closedir($dh);
        if (defined $pname) { $pfile = File::Spec->catfile($pdir, $pname); last }
        sleep 0.1;
    }
    ok($pfile && -f $pfile, "persistent runner wrote its pfile") or die "no pfile\n";
    my $data = decode_json(do { open(my $pf, '<', $pfile) or die $!; local $/; <$pf> });
    $runner_pid = $data->{pid};
    $runner_dir = $data->{dir};
    ok($runner_pid && kill(0, $runner_pid), "runner alive (pid $runner_pid)") or die "runner dead\n";

    # 3. Wait for the preload-root to come up and record its pid.
    for (1 .. 600) { last if -s $root_pidfile; sleep 0.1 }
    ok(-s $root_pidfile, "preload-root recorded its pid") or die "no preload-root pid\n";
    chomp($root_pid = do { open(my $rf, '<', $root_pidfile) or die $!; <$rf> });
    ok($root_pid && kill(0, $root_pid), "preload-root alive (pid $root_pid)") or die "preload-root dead\n";

    # 4. Background a `yath run` of both tests (-j1: a_inflight runs, z_pending pends).
    $run_pid = spawn_to(File::Spec->catfile($outdir, 'run.out'), @base, 'run', $tdir, '--ext=tx');
    ok($run_pid, "backgrounded `yath run`") or die "no run pid\n";

    # 5. Wait until the in-flight test is actually running.
    for (1 .. 600) {
        last if -s $inflight_pid;
        if (waitpid($run_pid, WNOHANG) == $run_pid) {
            my $ro = -f File::Spec->catfile($outdir, 'run.out')
                ? do { open(my $rh, '<', File::Spec->catfile($outdir, 'run.out')); local $/; <$rh> } : '(no run.out)';
            die "`yath run` exited before the in-flight test started; run.out:\n$ro\n";
        }
        sleep 0.1;
    }
    ok(-s $inflight_pid, "in-flight test is running") or die "in-flight test never started\n";

    # 6. SIGKILL the live preload-root (crash, mid-run, with a job in flight).
    ok(kill('KILL', $root_pid), "SIGKILL'd the live preload-root");

    # 7. Release the in-flight test so it finishes (it must survive the preload-root death).
    open(my $g, '>', $gofile) or die $!; close($g);

    # 8. `yath run` must complete and exit 0 -- the in-flight test finished and the
    #    runner respawned the preload-root to run the pending test.
    my $exit;
    for (1 .. 1200) {
        if (waitpid($run_pid, WNOHANG) == $run_pid) { $exit = $?; last }
        sleep 0.1;
    }
    $run_pid = undef if defined $exit;
    ok(defined($exit), "`yath run` completed (did not hang)") or die "run hung\n";
    is($exit, 0, "the run recovered from the preload-root crash and exited 0");

    my $out = do { open(my $rh, '<', File::Spec->catfile($outdir, 'run.out')) or die $!; local $/; <$rh> };
    like($out, qr{PASSED.*a_inflight\.tx}, "the in-flight test survived the crash and passed");
    like($out, qr{PASSED.*z_pending\.tx}, "the pending test ran on the respawned preload-root and passed");

    # 9. Shut the persistent runner down cleanly.
    my $stop = spawn_to(File::Spec->catfile($outdir, 'stop.out'), @base, 'stop');
    waitpid($stop, 0);

    1;
};
my $err = $@;

$cleanup->();

ok($ok, "test ran without a fatal error") or diag($err);

done_testing;
