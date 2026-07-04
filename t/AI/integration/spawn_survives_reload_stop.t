use Test2::V0;
use v5.38;
# HARNESS-DURATION-LONG

# Ticket TODO-119: the detached `yath spawn` supervisor must OUTLIVE stage teardown.
#
# The stage host double-forks + setsid's the spawn INTERMEDIATE (so pgid == the
# intermediate's pid) and watch_pid's that pid; its wind-down killall on `yath
# reload` / `yath stop` TERM/-KILLs `-<intermediate-pid>` -- the intermediate's whole
# process group. Before the fix the supervisor was forked from the intermediate and
# stayed in that group, so stage teardown killed the "detached" session: exit_status
# was never delivered (the command saw a bare control-EOF -> exit 255 "supervisor
# vanished") and the still-running script child was orphaned.
#
# The fix (launch_spawn's first act: setpgrp(0,0) into the supervisor's own group)
# proves out here end to end against a real `yath start -P<Preload>` runner:
#   * the supervisor AND the script child survive `yath reload` AND `yath stop`, and
#   * when the script finally exits, the command still receives its exit status
#     (exit 42), NOT the vanish diagnostic.
#
# Driven via run_cmd (a live command process) rather than App::Yath2::Tester, so the
# spawn session stays open across the reload/stop while we probe the pids directly.

use File::Temp qw/tempdir tempfile/;
use File::Spec;
use POSIX qw/:sys_wait_h/;
use Time::HiRes qw/sleep time/;

use App::Yath2::Tester qw/yath/;
use App::Yath2::Util qw/find_yath/;
use Test2::Harness2::Util::IPC qw/run_cmd/;
use Test2::Harness2::IPC ();

use Test2::Util qw/CAN_REALLY_FORK/;
skip_all "This test requires forking" if $ENV{T2_NO_FORK} || !CAN_REALLY_FORK;
skip_all "This feature requires IO::FDPass"
    unless eval { require IO::FDPass; 1 };
skip_all "This test requires process groups (setpgrp/killall by pgroup)"
    unless Test2::Harness2::IPC::USE_P_GROUPS();

require App::Yath2;
my $apppath = App::Yath2->app_path;
my $yath    = find_yath;

my $tmpdir = tempdir(CLEANUP => 1);
mkdir("$tmpdir/lib") or die "mkdir: $!";

{
    open(my $fh, '>', "$tmpdir/lib/SpawnSurvive.pm") or die "preload: $!";
    print $fh <<'    EOT';
package SpawnSurvive;
use strict;
use warnings;
use Test2::Harness2::Runner::Preload;
stage DEFAULT => sub { default() };
1;
    EOT
    close($fh);
}

# The spawned script: record "<my-pid> <supervisor-pid>" (getppid == the supervisor,
# which forked us; our own setsid does not change ppid), announce readiness, then
# spin until a trigger file appears and exit 42. Keeping it alive across the reload
# AND the stop lets us prove the supervisor is still watching when it finally exits.
my $pidfile  = "$tmpdir/spawn_pids.txt";
my $gofile   = "$tmpdir/go_exit";
my $reporter = "$tmpdir/reporter.pl";
{
    open(my $fh, '>', $reporter) or die "script: $!";
    print $fh <<"    EOT";
use Time::HiRes ();
open(my \$o, '>', "$pidfile") or die "pid: \$!";
print \$o "\$\$ " . getppid() . "\\n";
close(\$o);
\$| = 1;
print STDOUT "REPORTER-READY\\n";
until (-e "$gofile") { Time::HiRes::sleep(0.05) }
exit(42);
    EOT
    close($fh);
}

# --- Start a persistent runner WITH the preload. ---
yath(
    command => 'start',
    pre     => ["-D$tmpdir/lib"],
    args    => ["-I$tmpdir/lib", '-PSpawnSurvive'],
    exit    => 0,
);

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
        Time::HiRes::sleep(0.05);
    }
    return;
}

# Poll kill(0,$pid) until it goes false (dead) or the deadline passes. Returns true
# if the pid is STILL ALIVE at the deadline.
sub still_alive_after {
    my ($pid, $secs) = @_;
    my $deadline = time + $secs;
    while (time < $deadline) {
        return 0 unless kill(0, $pid);    # died -> not alive
        Time::HiRes::sleep(0.05);
    }
    return kill(0, $pid) ? 1 : 0;
}

# --- Open the spawn session (a live command process). ---
pipe(my $cmd_rh, my $cmd_wh) or die "pipe: $!";
my ($out_fh, $out_file) = tempfile(UNLINK => 1);
my ($err_fh, $err_file) = tempfile(UNLINK => 1);

my @cmd = ($^X, $yath, "-D$apppath", 'spawn', '--', $reporter);
my $cmd_pid = run_cmd(
    no_set_pgrp   => 1,
    stdin         => $cmd_rh,
    stdout        => $out_fh,
    stderr        => $err_fh,
    command       => \@cmd,
    run_in_parent => [sub { close($cmd_rh); close($out_fh); close($err_fh) }],
);

my ($child, $sup) = wait_for_pids($pidfile);
ok($child && $sup, "spawned script recorded its pid ($child) and its supervisor pid ($sup)")
    or do { kill('KILL', $cmd_pid); waitpid($cmd_pid, 0); done_testing; exit };

ok(kill(0, $child), "the script child is alive mid-session");
ok(kill(0, $sup),   "the supervisor is alive mid-session");

# --- `yath reload`: the runner re-execs the whole preload tree; the stage that
# hosted the spawn winds down and its killall TERM/-HUPs the intermediate's pgroup.
# The supervisor (now in its own group) must survive. ---
yath(command => 'reload', exit => 0);

# Watch a window while the reload's stage teardown (and its killall) fires: the
# supervisor must NOT die during it.
ok(still_alive_after($sup, 5), "supervisor stayed alive through the reload's stage teardown (not swept by killall)");
ok(kill(0, $child), "script child survived the reload");

# --- `yath stop`: full runner + stage teardown. Same killall path. The detached
# supervisor + script child must STILL be alive afterwards. This is the crux: before
# TODO-119 the stage teardown killed the supervisor here. ---
yath(command => 'stop', exit => 0);

ok(kill(0, $sup),   "supervisor survived `yath stop` (the detached session outlived teardown)");
ok(kill(0, $child), "script child survived `yath stop`");

# --- Let the script exit. With the supervisor still watching, its exit status (42)
# reaches the command -- proving the control channel and exit-status duty survived. ---
{ open(my $g, '>', $gofile) or die "go: $!"; close($g) }

my $reaped   = 0;
my $deadline = time + 30;
until ($reaped || time > $deadline) {
    $reaped = 1 if waitpid($cmd_pid, WNOHANG) == $cmd_pid;
    Time::HiRes::sleep(0.05);
}
my $status = $?;
unless ($reaped) { kill('KILL', $cmd_pid); waitpid($cmd_pid, 0) }

ok($reaped, "the spawn command exited once the script finished (no hang)");
is($status & 127, 0, "the command exited normally (not itself signal-killed)");
is($status >> 8, 42, "the command received the script's REAL exit status (42), not a vanish/false code");

my $err = '';
if (-f $err_file) { open(my $r, '<', $err_file); local $/; $err = <$r>; close($r) }
unlike($err, qr/supervisor vanished before reporting an exit status/,
    "no 'supervisor vanished' diagnostic (the supervisor was NOT killed by teardown)");

# --- Cleanup: both should be gone now; net any stragglers. ---
my $child_gone = 0;
my $sup_gone   = 0;
$deadline = time + 10;
until (($child_gone && $sup_gone) || time > $deadline) {
    $child_gone = 1 unless kill(0, $child);
    $sup_gone   = 1 unless kill(0, $sup);
    Time::HiRes::sleep(0.05);
}
ok($child_gone, "the script child exited (no orphan left running)");
ok($sup_gone,   "the supervisor exited after delivering the exit status (no straggler)");

kill('KILL', -$child) if kill(0, $child);
kill('KILL', $child)  if kill(0, $child);
kill('KILL', $sup)    if kill(0, $sup);

done_testing;
