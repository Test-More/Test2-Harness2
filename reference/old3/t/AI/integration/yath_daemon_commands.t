use strict;
use warnings;

use Test2::V0;
use Test2::Require::AuthorTesting;

use File::Temp qw/tempdir/;
use File::Spec ();
use POSIX qw/:sys_wait_h/;
use Time::HiRes qw/sleep time/;

# Smoke test for `yath list`, `yath status`, `yath stop`, `yath kill`.
# Start a daemon, verify list+status see it, stop it, then start
# another and kill it.

my $yath    = _find_yath();
my $tmproot = tempdir(CLEANUP => 1);
my $workdir = File::Spec->catdir($tmproot, 'wd');

# --- yath start ---
my ($start_out, $start_err, $start_exit) = _run_yath(
    $yath, $tmproot, ['start', '--workdir', $workdir, '-j1'], 'yath_start',
);
is($start_exit, 0, "yath start exited 0")
    or diag("stdout:\n$start_out\nstderr:\n$start_err");

my ($harness_pid) = $start_out =~ /^ started: \s+ pid = (\d+) /xm;
ok($harness_pid, "got harness pid: $harness_pid");
my ($ipc_path) = $start_out =~ /^ started: .* \s ipc = (\S+) /xm;
ok($ipc_path && -f $ipc_path, "IPC info file is in place: " . ($ipc_path // 'NONE'));

# --- yath list ---
my ($list_out, $list_err, $list_exit) = _run_yath(
    $yath, $tmproot, ['list'], 'yath_list',
);
is($list_exit, 0, "yath list exited 0")
    or diag("stdout:\n$list_out\nstderr:\n$list_err");
like($list_out, qr/\Q$harness_pid\E/, "list output includes the daemon pid");

# --- yath status ---
my ($status_out, $status_err, $status_exit) = _run_yath(
    $yath, $tmproot, ['status', '--workdir', $workdir], 'yath_status',
);
is($status_exit, 0, "yath status exited 0")
    or diag("stdout:\n$status_out\nstderr:\n$status_err");
like($status_out, qr/Service:/,   "status prints Service section");
like($status_out, qr/Resources:/, "status prints Resources section");
like($status_out, qr/state\s*:\s*running/, "status shows state running");

# --- yath stop ---
my ($stop_out, $stop_err, $stop_exit) = _run_yath(
    $yath, $tmproot, ['stop', '--workdir', $workdir], 'yath_stop',
);
is($stop_exit, 0, "yath stop exited 0")
    or diag("stdout:\n$stop_out\nstderr:\n$stop_err");
like($stop_out, qr/stopped: pid=\Q$harness_pid\E/, "stop reports the daemon stopped");

# Wait for cleanup; reap any zombies in case this test is the subreaper.
my $deadline = time() + 10;
my $gone;
while (time() < $deadline) {
    while ((my $kid = waitpid(-1, WNOHANG)) > 0) { }
    if (!kill(0 => $harness_pid) && !-e $ipc_path) {
        $gone = 1;
        last;
    }
    sleep(0.1);
}
ok($gone, "daemon pid gone + IPC info file unlinked after yath stop");

# --- yath kill on a fresh daemon ---
my $workdir2 = File::Spec->catdir($tmproot, 'wd2');
my ($s2_out, $s2_err, $s2_exit) = _run_yath(
    $yath, $tmproot, ['start', '--workdir', $workdir2, '-j1'], 'yath_start2',
);
is($s2_exit, 0, "second yath start exited 0")
    or diag("stdout:\n$s2_out\nstderr:\n$s2_err");
my ($pid2)  = $s2_out =~ /^ started: \s+ pid = (\d+) /xm;
my ($ipc2)  = $s2_out =~ /^ started: .* \s ipc = (\S+) /xm;
ok($pid2 && kill(0 => $pid2), "second daemon is alive ($pid2)");

my ($k_out, $k_err, $k_exit) = _run_yath(
    $yath, $tmproot, ['kill', '--workdir', $workdir2], 'yath_kill',
);
is($k_exit, 0, "yath kill exited 0")
    or diag("stdout:\n$k_out\nstderr:\n$k_err");
like($k_out, qr/killed \(SIG[A-Z]+\): pid=\Q$pid2\E/, "kill reports the daemon killed");

my $kdeadline = time() + 10;
my $kgone;
while (time() < $kdeadline) {
    while ((my $kid = waitpid(-1, WNOHANG)) > 0) { }
    if (!kill(0 => $pid2) && !-e $ipc2) {
        $kgone = 1;
        last;
    }
    sleep(0.1);
}
ok($kgone, "second daemon pid gone + IPC info file unlinked after yath kill");

done_testing;

sub _find_yath {
    my $local = File::Spec->catfile(_project_root(), 'scripts', 'yath');
    return $local if -x $local;
    return 'yath';
}

sub _project_root {
    my $here = File::Spec->rel2abs(__FILE__);
    my @parts = File::Spec->splitdir($here);
    pop @parts;
    while (@parts) {
        my $cand = File::Spec->catdir(@parts);
        return $cand if -f File::Spec->catfile($cand, 'ARCHITECTURE.md');
        pop @parts;
    }
    die "could not locate project root from $here";
}

sub _run_yath {
    my ($yath, $tmp, $extra, $log_tag) = @_;
    local $ENV{AUTHOR_TESTING} = 1;

    my $out_path = File::Spec->catfile($tmp, "${log_tag}.out");
    my $err_path = File::Spec->catfile($tmp, "${log_tag}.err");

    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        open(STDIN,  '<', '/dev/null') or die "redirect stdin: $!";
        open(STDOUT, '>', $out_path)   or die "redirect stdout: $!";
        open(STDERR, '>', $err_path)   or die "redirect stderr: $!";
        exec($yath, '-D', @$extra);
        die "exec: $!";
    }

    waitpid($pid, 0);
    my $exit = $? >> 8;

    my $out = do { local (@ARGV, $/) = ($out_path); <> } // '';
    my $err = do { local (@ARGV, $/) = ($err_path); <> } // '';
    unlink $out_path, $err_path;
    return ($out, $err, $exit);
}
