use Test2::V0;
use v5.38;
# HARNESS-DURATION-LONG

# Chunk 13 / ticket TODO-39: the two `yath spawn` behaviors the captured-output tester
# cannot exercise (ARCHITECTURE.md §4.8):
#
#   (b) STDIN round-trip -- the spawned child reads the command's REAL stdin
#       (fd passed via SCM_RIGHTS), so bytes written to the command's stdin reach
#       the child.
#   (d) kill-on-EOF -- the spawned process is detached from the harness but BOUND
#       to its command: when the `yath spawn` command dies (its control connection
#       EOFs), the supervisor kills the spawned process group. It does not outlive
#       the command.
#
# Both drive `yath spawn` directly (not via App::Yath2::Tester::yath, which
# captures output and supplies no stdin), against a real `yath start -P<Preload>`
# persistent runner.

use File::Temp qw/tempdir tempfile/;
use File::Spec;
use POSIX qw/:sys_wait_h/;
use Time::HiRes qw/sleep time/;

use App::Yath2::Tester qw/yath/;
use App::Yath2::Util qw/find_yath/;
use Test2::Harness2::Util::IPC qw/run_cmd/;

use Test2::Util qw/CAN_REALLY_FORK/;
skip_all "This test requires forking" if $ENV{T2_NO_FORK} || !CAN_REALLY_FORK;
skip_all "This feature requires IO::FDPass"
    unless eval { require IO::FDPass; 1 };

require App::Yath2;
my $apppath = App::Yath2->app_path;
my $yath    = find_yath;

my $tmpdir = tempdir(CLEANUP => 1);
mkdir("$tmpdir/lib") or die "mkdir: $!";

{
    open(my $fh, '>', "$tmpdir/lib/SpawnIO.pm") or die "preload: $!";
    print $fh <<'    EOT';
package SpawnIO;
use strict;
use warnings;
use Test2::Harness2::Runner::Preload;
our $MARKER = "IO-PRELOAD-MARK";
stage DEFAULT => sub { default() };
1;
    EOT
    close($fh);
}

# stdin-echo script: read a line from STDIN, write it (uppercased) to an out file,
# then exit. Proves the command's real stdin fd reached the child.
my $echo_out = "$tmpdir/echo_out.txt";
my $echo_script = "$tmpdir/echo.pl";
{
    open(my $fh, '>', $echo_script) or die "script: $!";
    print $fh <<"    EOT";
my \$line = <STDIN>;
chomp(\$line) if defined \$line;
open(my \$o, '>', "$echo_out") or die "out: \$!";
print \$o "ECHO:" . (defined(\$line) ? uc(\$line) : 'UNDEF') . "\\n";
close(\$o);
exit(0);
    EOT
    close($fh);
}

# long-lived script: record its OWN pid + process-group, then sleep "forever". The
# kill-on-EOF test kills the command and asserts this process group dies.
my $pid_file = "$tmpdir/child_pid.txt";
my $sleep_script = "$tmpdir/sleeper.pl";
{
    open(my $fh, '>', $sleep_script) or die "script: $!";
    print $fh <<"    EOT";
use POSIX qw/setsid/;
open(my \$o, '>', "$pid_file") or die "pid: \$!";
print \$o "\$\$\\n";
close(\$o);
\$| = 1;
print STDOUT "SLEEPER-READY\\n";
sleep 1 while 1;
    EOT
    close($fh);
}

# --- Start a persistent runner WITH the preload. ---
yath(
    command => 'start',
    pre     => ["-D$tmpdir/lib"],
    args    => ["-I$tmpdir/lib", '-PSpawnIO'],
    exit    => 0,
);

# Build the `yath spawn` command line the way the tester does (so discovery via
# YATH_PERSISTENCE_DIR resolves the same persistent runner).
# Mirror App::Yath2::Tester's command shape: -D (a yath pre-command dev-lib) goes
# AFTER the yath script, never to perl.
sub spawn_cmd {
    my (@args) = @_;
    return ($^X, $yath, "-D$apppath", 'spawn', @args);
}

local $ENV{NESTED_YATH}    = 1;
local $ENV{YATH_SELF_TEST} = 1;

# --- (b) STDIN round-trip --------------------------------------------------
subtest stdin_roundtrip => sub {
    pipe(my $cmd_rh, my $cmd_wh) or die "pipe: $!";

    my @cmd = spawn_cmd('--', $echo_script);

    my $pid = run_cmd(
        no_set_pgrp => 1,
        stdin       => $cmd_rh,    # the command's STDIN is our pipe read-end
        command     => \@cmd,
        run_in_parent => [sub { close($cmd_rh) }],
    );

    # Feed a line into the command's stdin; the child reads it over the passed fd.
    print $cmd_wh "hello-from-stdin\n";
    $cmd_wh->flush;
    close($cmd_wh);

    my $reaped = 0;
    my $deadline = time + 30;
    until ($reaped || time > $deadline) {
        $reaped = 1 if waitpid($pid, WNOHANG) == $pid;
        sleep 0.05;
    }
    unless ($reaped) { kill('KILL', $pid); waitpid($pid, 0) }
    ok($reaped, "the spawn command completed");

    my $got = '';
    if (-f $echo_out) {
        open(my $r, '<', $echo_out) or die "read echo out: $!";
        local $/;
        $got = <$r>;
        close($r);
    }
    like($got, qr/ECHO:HELLO-FROM-STDIN/,
        "the spawned child read the command's REAL stdin (fd passed over the socket)");
};

# --- (d) kill-on-EOF: the spawned process dies with its command ------------
subtest kill_on_command_death => sub {
    unlink($pid_file) if -f $pid_file;

    my ($cmd_rh, $cmd_wh);
    pipe($cmd_rh, $cmd_wh) or die "pipe: $!";

    # Capture the command's stdout so we can wait for SLEEPER-READY.
    my ($out_fh, $out_file) = tempfile(UNLINK => 1);

    my @cmd = spawn_cmd('--', $sleep_script);

    my $pid = run_cmd(
        no_set_pgrp   => 1,
        stdin         => $cmd_rh,
        stdout        => $out_fh,
        stderr        => $out_fh,
        command       => \@cmd,
        run_in_parent => [sub { close($cmd_rh); close($out_fh) }],
    );

    # Wait for the sleeper to record its pid (it has been launched in the preload).
    my $child_pid;
    my $deadline = time + 30;
    until (defined($child_pid) || time > $deadline) {
        if (-s $pid_file) {
            open(my $r, '<', $pid_file) or last;
            my $p = <$r>;
            close($r);
            chomp($p) if defined $p;
            $child_pid = $p if defined($p) && $p =~ /^\d+$/;
        }
        sleep 0.05;
    }

    ok($child_pid, "the spawned sleeper recorded its pid (it launched in the preload)")
        or do { kill('KILL', $pid); waitpid($pid, 0); return };

    ok(kill(0, $child_pid), "the spawned process is alive while the command runs");

    # Kill the command: closing its end of the control connection is the
    # supervisor's "command died" signal -> it kills the spawned process group.
    kill('KILL', $pid);
    waitpid($pid, 0);
    close($cmd_wh);

    # The supervisor should now reap/kill the sleeper's process group.
    my $gone = 0;
    $deadline = time + 30;
    until ($gone || time > $deadline) {
        $gone = 1 unless kill(0, $child_pid);
        sleep 0.05;
    }

    ok($gone, "the spawned process was killed when the command died (bound to its command, not the harness)");

    # Safety net: if it somehow survived, clean it up so it does not leak.
    unless ($gone) {
        kill('KILL', -$child_pid) if kill(0, $child_pid);
        kill('KILL', $child_pid)  if kill(0, $child_pid);
    }
};

yath(command => 'stop', exit => 0);

done_testing;
