use Test2::V0;

# Chunk 17: a plugin setup() that starts a daemon-style background process via
# run_collected. Assert (1) its output is captured as (DAEMON)-tagged events,
# (2) the run completes without hanging on the never-exiting daemon, and (3) the
# daemon dies with the runner (the runner tracks it in AUX_PIDS and kills it at
# teardown; watch_parent_pid is the backstop).

use App::Yath2::Tester qw/yath/;
use File::Temp qw/tempfile/;
use Time::HiRes qw/sleep/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

my (undef, $pidfile) = tempfile("daemonpid-XXXXXX", TMPDIR => 1, OPEN => 0, UNLINK => 1);

yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '--no-plugins', '-pDaemonPlug'],
    env     => {DAEMON_PIDFILE => $pidfile},
    exit    => 0,
    test    => sub {
        my $out  = shift;
        my $text = $out->{output};

        like($text, qr/\(\s*DAEMON\s*\)\s+DAEMON TICK/, "run_collected daemon output captured as (DAEMON) events");

        my $dpid;
        if (open(my $fh, '<', $pidfile)) {
            chomp($dpid = <$fh> // '');
            close($fh);
        }
        ok($dpid, "daemon recorded its pid ($dpid)") or return;

        # The runner kills the daemon at teardown before it exits; once yath is
        # done the daemon must be gone (reaped, not a survivor). Allow a brief
        # grace for the reap/reparent to settle.
        my $alive = 1;
        for (1 .. 50) {
            unless (kill(0, $dpid)) { $alive = 0; last }
            sleep 0.1;
        }
        ok(!$alive, "daemon died with the runner (no orphan survived)");
    },
);

done_testing;
