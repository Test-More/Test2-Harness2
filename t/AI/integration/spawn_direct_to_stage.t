use Test2::V0;
use v5.38;
# HARNESS-DURATION-LONG

# Chunk 13 / ticket #39: `yath spawn` redesign -- direct-to-stage, SCM_RIGHTS
# fd-pass, detached supervisor (no exec), dedicated control protocol
# (ARCHITECTURE.md §4.8). End to end through App::Yath2::Tester against a real
# `yath start -P<Preload>` persistent runner.
#
# Proves:
#   (a) the spawned process runs in the PRELOADED interpreter (a preloaded
#       module's variable is visible to it),
#   (b) it gets the command's real STDOUT/STDERR (its output reaches the command's
#       captured output -- the command leaves the byte path; the child writes the
#       command's descriptors directly),
#   (c) it reports the correct exit / raw-wait status (exit code + signal death),
#   (d) it is cleanly REJECTED when no preload stage exists (a no-preload runner).

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath2::Tester qw/yath/;

use Test2::Util qw/CAN_REALLY_FORK/;
skip_all "This test requires forking" if $ENV{T2_NO_FORK} || !CAN_REALLY_FORK;
skip_all "This feature requires IO::FDPass"
    unless eval { require IO::FDPass; 1 };

# A preload that exposes a marker variable + a default stage. The spawned script
# reads $SpawnSmoke::MARKER -- only visible if the preload was preserved (no exec).
my $tmpdir = tempdir(CLEANUP => 1);
mkdir("$tmpdir/lib") or die "mkdir: $!";

{
    open(my $fh, '>', "$tmpdir/lib/SpawnSmoke.pm") or die "preload: $!";
    print $fh <<'    EOT';
package SpawnSmoke;
use strict;
use warnings;

use Test2::Harness2::Runner::Preload;

our $MARKER = "PRELOADED-MARKER-7f3a";

stage DEFAULT => sub { default() };

1;
    EOT
    close($fh);
}

# The script the spawn launches. Prints the preloaded marker (preload-preserved
# check + stdout round-trip), a stderr line (stderr round-trip), then exits 7.
my $script = "$tmpdir/spawn_script.pl";
{
    open(my $fh, '>', $script) or die "script: $!";
    print $fh <<'    EOT';
my $marker = $SpawnSmoke::MARKER // 'NO-MARKER-PRELOAD-LOST';
print STDOUT "SPAWN-STDOUT marker=$marker\n";
print STDERR "SPAWN-STDERR diagnostic line\n";
$| = 1;
exit(7);
    EOT
    close($fh);
}

# A script that kills itself with a signal, so the command re-raises the signal
# death (raw wait status, not just an exit code).
my $sig_script = "$tmpdir/spawn_sig.pl";
{
    open(my $fh, '>', $sig_script) or die "sig script: $!";
    print $fh <<'    EOT';
print STDOUT "SPAWN-ABOUT-TO-DIE\n";
$| = 1;
kill('TERM', $$);
sleep 5;
    EOT
    close($fh);
}

# --- Start a persistent runner WITH the preload. ---
yath(
    command => 'start',
    pre     => ["-D$tmpdir/lib"],
    args    => ["-I$tmpdir/lib", '-PSpawnSmoke'],
    exit    => 0,
);

# (a)+(b)+(c): preload-preserved + stdout/stderr round-trip + exit code. The
# tester captures the RAW wait status, so a clean exit(7) reads as 7<<8.
yath(
    command => 'spawn',
    args    => ['--', $script],
    test    => sub {
        my $out = shift;
        like($out->{output}, qr/SPAWN-STDOUT marker=PRELOADED-MARKER-7f3a/,
            "spawned process ran in the PRELOADED interpreter (preload var visible) and STDOUT reached the command");
        like($out->{output}, qr/SPAWN-STDERR diagnostic line/,
            "spawned process STDERR reached the command");
        unlike($out->{output}, qr/NO-MARKER-PRELOAD-LOST/,
            "the preload was NOT lost (no exec wiped it)");
        is($out->{exit} >> 8, 7, "the command exited with the spawned process's exit code (7)");
        is($out->{exit} & 127, 0, "no signal death on a clean exit");
    },
);

# (c): signal death is reported + re-raised (raw wait status, not just exit code).
yath(
    command => 'spawn',
    args    => ['--', $sig_script],
    test    => sub {
        my $out = shift;
        like($out->{output}, qr/SPAWN-ABOUT-TO-DIE/, "signal-death script ran and produced output");
        # Ticket #139 (finding 67): the message names the signal ($Config{sig_name}),
        # it is no longer the raw number, and there is no 'No such signal' warning.
        like($out->{output}, qr/Terminated with signal: TERM\./,
            "the command reported the child's signal death by NAME (SIGTERM)");
        unlike($out->{output}, qr/No such signal/,
            "no 'No such signal: SIG15' warning (the numeric %SIG write was dropped)");
        # The command re-raises the signal, so it dies by signal 15: exit = signal num.
        my $st = $out->{exit};
        ok(($st & 127) == 15, "the command itself died by the re-raised signal (SIGTERM)")
            or diag("raw exit status: $st");
    },
);

yath(command => 'stop', exit => 0);

# --- (d): a NO-PRELOAD persistent runner has no stage to host a spawn -> reject. ---
my $emptydir = tempdir(CLEANUP => 1);
yath(
    command => 'start',
    exit    => 0,
);

yath(
    command => 'spawn',
    args    => ['--', $script],
    exit    => T(),    # non-zero: the spawn is rejected
    test    => sub {
        my $out = shift;
        like($out->{output}, qr/No live preload stage/,
            "spawn is cleanly rejected when the runner has no preload stage");
        unlike($out->{output}, qr/PRELOADED-MARKER/, "the script never ran");
    },
);

yath(command => 'stop', exit => 0);

done_testing;
