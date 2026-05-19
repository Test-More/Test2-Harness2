use strict;
use warnings;

use Test2::V0;
use Test2::Require::AuthorTesting;

use File::Temp qw/tempdir/;
use File::Spec ();
use POSIX qw/:sys_wait_h/;
use Time::HiRes qw/sleep time/;

# Smoke test for `yath run`: start a daemon via `yath start`, queue
# a passing test via `yath run --workdir DIR`, assert exit 0; queue
# a failing test, assert non-zero exit; then TERM the daemon.

my $yath    = _find_yath();
my $tmproot = tempdir(CLEANUP => 1);
my $workdir = File::Spec->catdir($tmproot, 'wd');

my ($start_out, $start_err, $start_exit) = _run_yath_start(
    $yath, $workdir, $tmproot,
);
is($start_exit, 0, "yath start exited 0")
    or diag("stdout:\n$start_out\nstderr:\n$start_err");

my ($harness_pid) = $start_out =~ /^ started: \s+ pid = (\d+) /xm;
ok($harness_pid, "got harness pid: $harness_pid");

# `yath start` prints "started: pid=N workdir=... ipc=PATH" -- parse the
# IPC path directly rather than guessing where the file landed (it goes
# to the system tmp, not $workdir/tmp).
my ($ipc_file) = $start_out =~ /^ started: .* \s ipc = (\S+) /xm;
ok($ipc_file && -f $ipc_file, "IPC info file is in place: " . ($ipc_file // 'NONE'));

# Two fixtures: a passing test and a failing one.
my $pass_t = File::Spec->catfile($tmproot, 'pass.t');
my $fail_t = File::Spec->catfile($tmproot, 'fail.t');
_write_file($pass_t, "use Test2::V0; ok(1, 'pass'); done_testing;\n");
_write_file($fail_t, "use Test2::V0; ok(0, 'fail'); done_testing;\n");

# Pass run
my ($pass_out, $pass_err, $pass_exit) = _run_yath_run(
    $yath, $tmproot, ['--workdir', $workdir, $pass_t],
);
is($pass_exit, 0, "yath run on passing test exits 0")
    or diag("stdout:\n$pass_out\nstderr:\n$pass_err");

# Fail run
my ($fail_out, $fail_err, $fail_exit) = _run_yath_run(
    $yath, $tmproot, ['--workdir', $workdir, $fail_t],
);
isnt($fail_exit, 0, "yath run on failing test exits non-zero")
    or diag("stdout:\n$fail_out\nstderr:\n$fail_err");

# Tear down: TERM daemon, reap zombies, confirm cleanup.
kill TERM => $harness_pid if $harness_pid;
my $cleanup_deadline = time() + 10;
my $cleaned;
while (time() < $cleanup_deadline) {
    while ((my $kid = waitpid(-1, WNOHANG)) > 0) { }
    if (!kill(0 => $harness_pid) && !-e $ipc_file) {
        $cleaned = 1;
        last;
    }
    sleep(0.1);
}
ok($cleaned, "daemon exited + IPC file cleaned up after TERM");

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

sub _write_file {
    my ($path, $content) = @_;
    open(my $fh, '>', $path) or die "open '$path': $!";
    print $fh $content;
    close $fh or die "close '$path': $!";
}

sub _run_yath_cmd {
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

sub _run_yath_start {
    my ($yath, $workdir, $tmp) = @_;
    return _run_yath_cmd(
        $yath, $tmp,
        ['start', '--workdir', $workdir, '-j1'],
        'yath_start',
    );
}

sub _run_yath_run {
    my ($yath, $tmp, $extra) = @_;
    return _run_yath_cmd(
        $yath, $tmp,
        ['run', @$extra],
        'yath_run_' . int(time() * 1000) . "_$$",
    );
}
