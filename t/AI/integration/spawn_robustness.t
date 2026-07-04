use Test2::V0;
use v5.38;
# HARNESS-DURATION-LONG

# Ticket TODO-139: the `yath spawn` robustness bundle, end to end against a real
# `yath start -P<Preload>` persistent runner. Covers:
#
#   * finding 6+G2  -- the command exits NON-ZERO with a vanish message when the
#                      supervisor is SIGKILLed mid-session (never a false exit 0).
#   * finding 23    -- the detached supervisor's inherited stage fds are swept:
#                      its 0/1/2 are reopened onto /dev/null; the script child's
#                      0/1/2 are the passed terminal fds (via /proc inspection).
#   * finding 12+G5 -- a TERM-ignoring spawned script is escalated to KILL within
#                      the ~5s grace window when the command dies; no stuck
#                      supervisor.
#   * finding 67    -- a signal-terminated spawn prints a NAMED signal ("TERM."),
#                      emits no 'No such signal' warning, and dies by that signal.
#
# These drive `yath spawn` directly (run_cmd) rather than App::Yath2::Tester
# (which captures output and supplies no stdin / no live command process to kill).

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

my $have_proc = -d "/proc/$$/fd";

require App::Yath2;
my $apppath = App::Yath2->app_path;
my $yath    = find_yath;

my $tmpdir = tempdir(CLEANUP => 1);
mkdir("$tmpdir/lib") or die "mkdir: $!";

{
    open(my $fh, '>', "$tmpdir/lib/SpawnRobust.pm") or die "preload: $!";
    print $fh <<'    EOT';
package SpawnRobust;
use strict;
use warnings;
use Test2::Harness2::Runner::Preload;
stage DEFAULT => sub { default() };
1;
    EOT
    close($fh);
}

# Reporter: record "<my-pid> <supervisor-pid>" (getppid == the supervisor, which
# forked us then we setsid'd -- setsid does not change ppid), announce readiness,
# then sleep forever WITHOUT reading stdin.
my $rep_pidfile = "$tmpdir/reporter_pids.txt";
my $reporter    = "$tmpdir/reporter.pl";
{
    open(my $fh, '>', $reporter) or die "script: $!";
    print $fh <<"    EOT";
open(my \$o, '>', "$rep_pidfile") or die "pid: \$!";
print \$o "\$\$ " . getppid() . "\\n";
close(\$o);
\$| = 1;
print STDOUT "REPORTER-READY\\n";
sleep 1 while 1;
    EOT
    close($fh);
}

# TERM-ignoring sleeper: traps TERM to IGNORE, records its pids, sleeps forever.
my $ti_pidfile = "$tmpdir/term_ignore_pids.txt";
my $term_ignore = "$tmpdir/term_ignore.pl";
{
    open(my $fh, '>', $term_ignore) or die "script: $!";
    print $fh <<"    EOT";
\$SIG{TERM} = 'IGNORE';
open(my \$o, '>', "$ti_pidfile") or die "pid: \$!";
print \$o "\$\$ " . getppid() . "\\n";
close(\$o);
\$| = 1;
print STDOUT "TI-READY\\n";
sleep 1 while 1;
    EOT
    close($fh);
}

# Self-signal: raise TERM on ourselves (default disposition -> die by signal 15).
my $sig_script = "$tmpdir/self_sig.pl";
{
    open(my $fh, '>', $sig_script) or die "script: $!";
    print $fh <<'    EOT';
$| = 1;
print STDOUT "SIG-READY\n";
kill('TERM', $$);
sleep 10;
    EOT
    close($fh);
}

# --- Start a persistent runner WITH the preload. ---
yath(
    command => 'start',
    pre     => ["-D$tmpdir/lib"],
    args    => ["-I$tmpdir/lib", '-PSpawnRobust'],
    exit    => 0,
);

sub spawn_cmd {
    my (@args) = @_;
    return ($^X, $yath, "-D$apppath", 'spawn', @args);
}

local $ENV{NESTED_YATH}    = 1;
local $ENV{YATH_SELF_TEST} = 1;

sub read_two_pids {
    my ($file) = @_;
    return unless -s $file;
    open(my $r, '<', $file) or return;
    my $line = <$r>;
    close($r);
    return unless defined $line;
    my ($c, $s) = $line =~ /^(\d+)\s+(\d+)/;
    return ($c, $s);
}

sub wait_for_pids {
    my ($file) = @_;
    my $deadline = time + 30;
    while (time < $deadline) {
        my ($c, $s) = read_two_pids($file);
        return ($c, $s) if $c && $s;
        sleep 0.05;
    }
    return;
}

# --- fd-sweep (finding 23) + supervisor vanish (finding 6+G2) ----------------
subtest sweep_and_supervisor_vanish => sub {
    unlink($rep_pidfile) if -f $rep_pidfile;

    pipe(my $cmd_rh, my $cmd_wh) or die "pipe: $!";
    my ($out_fh, $out_file) = tempfile(UNLINK => 1);
    my ($err_fh, $err_file) = tempfile(UNLINK => 1);

    my @cmd = spawn_cmd('--', $reporter);
    my $pid = run_cmd(
        no_set_pgrp   => 1,
        stdin         => $cmd_rh,
        stdout        => $out_fh,
        stderr        => $err_fh,
        command       => \@cmd,
        run_in_parent => [sub { close($cmd_rh); close($out_fh); close($err_fh) }],
    );

    my ($child, $sup) = wait_for_pids($rep_pidfile);
    ok($child && $sup, "reporter recorded its pid and its supervisor pid")
        or do { kill('KILL', $pid); waitpid($pid, 0); return };

    # Finding 23: the swept supervisor holds /dev/null on 0/1/2; the script child
    # holds the PASSED terminal fds (not /dev/null).
  SKIP: {
        skip "no Linux-style /proc", 3 unless $have_proc && -d "/proc/$sup/fd";
        my @sup_std   = map { readlink("/proc/$sup/fd/$_")   // '' } 0 .. 2;
        my @child_std = map { readlink("/proc/$child/fd/$_") // '' } 0 .. 2;

        is([@sup_std], [('/dev/null') x 3],
            "supervisor 0/1/2 were swept onto /dev/null (inherited stage fds released)");
        ok((grep { $_ ne '/dev/null' && length($_) } @child_std) >= 2,
            "script child 0/1/2 are the passed terminal fds, not /dev/null")
            or diag("child std fds: @child_std");
        ok(1, "proc inspection ran");
    }

    ok(kill(0, $sup), "the supervisor is alive mid-session");

    # Finding 6+G2: SIGKILL the supervisor. Its control channel EOFs WITHOUT an
    # exit_status frame -> the command must exit NON-ZERO with the vanish message,
    # never a false exit 0.
    kill('KILL', $sup);

    my $reaped = 0;
    my $deadline = time + 30;
    until ($reaped || time > $deadline) {
        $reaped = 1 if waitpid($pid, WNOHANG) == $pid;
        sleep 0.05;
    }
    my $status = $?;
    unless ($reaped) { kill('KILL', $pid); waitpid($pid, 0) }

    ok($reaped, "the spawn command exited after the supervisor was killed (no hang)");
    is($status & 127, 0, "command exited normally (not itself signal-killed)");
    is($status >> 8, 255, "command exited 255 (supervisor vanished -> not a false exit 0)");

    my $err = '';
    if (-f $err_file) { open(my $r, '<', $err_file); local $/; $err = <$r>; close($r) }
    like($err, qr/supervisor vanished before reporting an exit status/,
        "the command printed the vanish diagnostic");

    # The orphaned reporter outlived its (killed) supervisor: clean it up.
    kill('KILL', -$child) if $child && kill(0, $child);
    kill('KILL', $child)  if $child && kill(0, $child);
};

# --- TERM-ignoring script escalated to KILL within grace (finding 12+G5) -----
subtest term_ignore_escalated_to_kill => sub {
    unlink($ti_pidfile) if -f $ti_pidfile;

    pipe(my $cmd_rh, my $cmd_wh) or die "pipe: $!";
    my ($out_fh, $out_file) = tempfile(UNLINK => 1);

    my @cmd = spawn_cmd('--', $term_ignore);
    my $pid = run_cmd(
        no_set_pgrp   => 1,
        stdin         => $cmd_rh,
        stdout        => $out_fh,
        stderr        => $out_fh,
        command       => \@cmd,
        run_in_parent => [sub { close($cmd_rh); close($out_fh) }],
    );

    my ($child, $sup) = wait_for_pids($ti_pidfile);
    ok($child && $sup, "TERM-ignoring script recorded its pids")
        or do { kill('KILL', $pid); waitpid($pid, 0); return };

    ok(kill(0, $child), "the TERM-ignoring script is alive while the command runs");

    # Kill the command: control EOF -> supervisor TERMs the group (ignored), grace
    # ~5s, then escalates to KILL. The script must die within the grace window.
    kill('KILL', $pid);
    waitpid($pid, 0);
    close($cmd_wh);

    my $gone = 0;
    my $t0 = time;
    my $deadline = time + 20;
    until ($gone || time > $deadline) {
        $gone = 1 unless kill(0, $child);
        sleep 0.05;
    }
    ok($gone, "the TERM-ignoring script was KILL-escalated and reaped after the grace window");
    diag(sprintf("child died %.1fs after command death", time - $t0)) if $gone;

    # The supervisor must not be stuck: it reaps the child then _exit(0).
    my $sup_gone = 0;
    $deadline = time + 15;
    until ($sup_gone || time > $deadline) {
        $sup_gone = 1 unless kill(0, $sup);
        sleep 0.05;
    }
    ok($sup_gone, "the supervisor exited (no permanently stuck blocking waitpid)");

    # Safety net.
    unless ($gone) {
        kill('KILL', -$child) if kill(0, $child);
        kill('KILL', $child)  if kill(0, $child);
    }
};

# --- signal-terminated spawn prints a NAMED signal (finding 67) --------------
subtest signal_named_no_warning => sub {
    pipe(my $cmd_rh, my $cmd_wh) or die "pipe: $!";
    my ($out_fh, $out_file) = tempfile(UNLINK => 1);
    my ($err_fh, $err_file) = tempfile(UNLINK => 1);

    my @cmd = spawn_cmd('--', $sig_script);
    my $pid = run_cmd(
        no_set_pgrp   => 1,
        stdin         => $cmd_rh,
        stdout        => $out_fh,
        stderr        => $err_fh,
        command       => \@cmd,
        run_in_parent => [sub { close($cmd_rh); close($out_fh); close($err_fh) }],
    );
    close($cmd_wh);

    my $reaped = 0;
    my $deadline = time + 30;
    until ($reaped || time > $deadline) {
        $reaped = 1 if waitpid($pid, WNOHANG) == $pid;
        sleep 0.05;
    }
    my $status = $?;
    unless ($reaped) { kill('KILL', $pid); waitpid($pid, 0) }
    ok($reaped, "the spawn command exited");

    is($status & 127, 15, "the command re-raised and died by signal 15 (TERM)");

    my $err = '';
    if (-f $err_file) { open(my $r, '<', $err_file); local $/; $err = <$r>; close($r) }
    like($err, qr/Terminated with signal: TERM\./,
        "the command named the signal (TERM), not a bare number");
    unlike($err, qr/No such signal/,
        "no 'No such signal: SIG15' warning (the numeric %SIG write was dropped)");
};

yath(command => 'stop', exit => 0);

done_testing;
