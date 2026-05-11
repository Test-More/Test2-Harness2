use strict;
use warnings;

use Test2::V0;
use Test2::Require::AuthorTesting;

use File::Temp qw/tempdir/;
use File::Spec ();
use POSIX qw/:sys_wait_h/;
use Time::HiRes qw/sleep time/;

# Smoke test for `yath start`: spawn a daemon, verify it prints the
# "started:" breadcrumb with pid + workdir + ipc path, the harness
# pid is alive, the IPC info file exists, then send the daemon TERM
# and confirm the watchdog cleans up the IPC file.

my $yath  = _find_yath();
my $devlib = _find_dev_lib();

my $tmproot = tempdir(CLEANUP => 1);
my $workdir = File::Spec->catdir($tmproot, 'wd');

my ($parent_stdout, $parent_stderr, $parent_exit) = _run_yath_start(
    $yath, $devlib, $workdir, $tmproot,
);

is($parent_exit, 0, "yath start parent exited 0")
    or diag("stdout:\n$parent_stdout\nstderr:\n$parent_stderr");

my ($harness_pid, $ipc_path) = _parse_started_line($parent_stdout);
ok($harness_pid && $harness_pid > 0, "got a numeric harness pid ($harness_pid)");
ok(defined $ipc_path && length $ipc_path, "got an IPC info path ($ipc_path)");

my $alive_deadline = time() + 5;
my $alive = 0;
while (time() < $alive_deadline) {
    if (kill 0 => $harness_pid) { $alive = 1; last }
    sleep(0.05);
}
ok($alive, "harness pid $harness_pid is running");

ok(-f $ipc_path, "IPC info file is present at $ipc_path");

# Tear down: TERM the harness; watchdog should unlink the IPC file
# once the daemon is gone.
kill TERM => $harness_pid if $alive;

my $cleanup_deadline = time() + 10;
my $cleaned;
while (time() < $cleanup_deadline) {
    # Reap any zombies. yath start's POSIX::_exit leaves the daemon
    # an orphan, but this test process may be the subreaper for it
    # (Test2 / yath nest detection), in which case kill(0) reports
    # the zombie as alive until we explicitly reap it.
    while ((my $kid = waitpid(-1, WNOHANG)) > 0) { }

    if (!kill(0 => $harness_pid) && !-e $ipc_path) {
        $cleaned = 1;
        last;
    }
    sleep(0.1);
}
ok($cleaned, "harness pid gone + IPC info file unlinked after TERM");

done_testing;

sub _find_yath {
    my $root  = _project_root();
    my $local = File::Spec->catfile($root, 'scripts', 'yath');
    return $local if -x $local;
    # Fall back to the installed yath; the harness CLAUDE.md notes
    # this works as long as -D is between yath and the command.
    return 'yath';
}

sub _find_dev_lib {
    my $root = _project_root();
    return File::Spec->catdir($root, 'lib');
}

sub _project_root {
    # Walk up from this file until we find ARCHITECTURE.md (the
    # checkout root marker used elsewhere in t/AI).
    my $here = File::Spec->rel2abs(__FILE__);
    my @parts = File::Spec->splitdir($here);
    pop @parts;    # drop filename
    while (@parts) {
        my $candidate = File::Spec->catdir(@parts);
        return $candidate if -f File::Spec->catfile($candidate, 'ARCHITECTURE.md');
        pop @parts;
    }
    die "could not locate project root from $here";
}

sub _run_yath_start {
    my ($yath, $devlib, $workdir, $tmp) = @_;

    local $ENV{AUTHOR_TESTING} = 1;

    # Use file redirects, not pipes. The daemon child inherits the
    # parent's STDOUT/STDERR; if those are pipes back to this test
    # process, the read end never sees EOF (daemon keeps writing
    # to its inherited fds forever) and the test deadlocks.
    my $out_path = File::Spec->catfile($tmp, 'yath_start.out');
    my $err_path = File::Spec->catfile($tmp, 'yath_start.err');

    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        open(STDIN,  '<', '/dev/null') or die "redirect stdin: $!";
        open(STDOUT, '>', $out_path)   or die "redirect stdout: $!";
        open(STDERR, '>', $err_path)   or die "redirect stderr: $!";
        exec($yath, '-D', 'start', '--workdir', $workdir, '-j1');
        die "exec: $!";
    }

    waitpid($pid, 0);
    my $exit = $? >> 8;

    my $stdout = do { local (@ARGV, $/) = ($out_path); <> } // '';
    my $stderr = do { local (@ARGV, $/) = ($err_path); <> } // '';

    unlink $out_path, $err_path;

    return ($stdout, $stderr, $exit);
}

sub _parse_started_line {
    my ($stdout) = @_;
    for my $line (split /\n/, $stdout) {
        next unless $line =~ /\A started: \s+
                              pid = (\d+) \s+
                              workdir = (\S+) \s+
                              ipc = (\S+) /x;
        return ($1, $3);
    }
    diag("yath start stdout did not contain a 'started:' line:\n$stdout");
    return (undef, undef);
}
