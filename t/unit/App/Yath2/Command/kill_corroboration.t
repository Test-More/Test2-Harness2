use Test2::V0;

use File::Temp qw/tempdir tempfile/;
use File::Spec;
use Time::HiRes qw/time/;

use Test2::Util qw/CAN_REALLY_FORK/;

# Unit coverage for ticket #121's KILL-safety corroboration predicate and its
# helpers on the shared base App::Yath2::Command::run. These are the guarantees the
# "recycled pid can NEVER be signaled" proof rests on, exercised WITHOUT starting a
# real runner: the predicate is pure over ($disco, $pid) plus a `ps` identity probe.
skip_all "This test requires forking" if $ENV{T2_NO_FORK} || !CAN_REALLY_FORK;

require App::Yath2::Command::run;
require App::Yath2::Discovery;

# A bare object is enough: every helper under test takes ($disco, $pid[, $ack]) and
# only ever reaches back into $self for sibling helpers (all defined on the class).
my $cmd = bless {}, 'App::Yath2::Command::run';

# Is `ps -o args=` usable here? If our own pid's args come back empty, the ps-based
# identity arm cannot be exercised; the predicate then fail-safes to "not corroborated"
# (which we still assert, just from a different cause), so skip the ps-positive cases.
my $ps_ok = do {
    my $out = '';
    eval { $out = qx{ps -p $$ -o args= 2>/dev/null}; 1 };
    defined($out) && length($out) ? 1 : 0;
};

my @reap;
# local $?: waitpid stamps the reaped child's signal status into $?, and Perl uses
# $? as the process exit code -- without this the test process would "exit 9".
END { local $?; for my $p (@reap) { next unless $p; kill('KILL', $p); waitpid($p, 0) } }

# Fork a long-lived child with a chosen $0 (process name). Returns its pid once it
# has set its name and signalled readiness over a pipe.
sub named_child {
    my ($name) = @_;

    pipe(my $r, my $w) or die "pipe: $!";
    my $pid = fork();
    die "fork: $!" unless defined $pid;

    if (!$pid) {
        close($r);
        $0 = $name if defined $name;
        $SIG{TERM} = sub { exit 0 };
        syswrite($w, "1");
        close($w);
        sleep 1 while 1;
        exit 0;
    }

    close($w);
    my $buf = '';
    sysread($r, $buf, 1);
    close($r);

    push @reap => $pid;
    return $pid;
}

# A pid guaranteed dead (fork + reap) so kill(0) reports ESRCH.
sub dead_pid {
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) { exit 0 }
    waitpid($pid, 0);
    return $pid;
}

# Build a Discovery bound to a fresh workdir with a PID file naming $pid. No socket
# and no symlink are needed: corroborate_runner reads workdir/PID FRESH on every call.
sub disco_for {
    my ($pid) = @_;
    my $workdir = tempdir(CLEANUP => 1);

    if (defined $pid) {
        open(my $fh, '>', File::Spec->catfile($workdir, 'PID')) or die "PID: $!";
        print $fh "$pid\n";
        close($fh);
    }

    return App::Yath2::Discovery->new(
        link    => File::Spec->catfile($workdir, 'the.sock'),
        workdir => $workdir,
    );
}

subtest constants => sub {
    is($cmd->STOP_DEADLINE, 30, "STOP_DEADLINE default 30");
    is($cmd->KILL_GRACE,    5,  "KILL_GRACE default 5");

    local $ENV{YATH_STOP_DEADLINE} = 3;
    local $ENV{YATH_KILL_GRACE}    = 1;
    is($cmd->STOP_DEADLINE, 3, "STOP_DEADLINE honors the env override (tests shrink it)");
    is($cmd->KILL_GRACE,    1, "KILL_GRACE honors the env override");
};

subtest runner_identity_ok => sub {
    # pid<=1 is never a runner (own-process-group guard).
    is($cmd->runner_identity_ok(1,     undef), 0, "pid 1 is never corroborated");
    is($cmd->runner_identity_ok(0,     undef), 0, "pid 0 is never corroborated");
    is($cmd->runner_identity_ok(undef, undef), 0, "undef pid is never corroborated");

    unless ($ps_ok) {
        skip_all => "ps -o args= unavailable; ps-identity arm cannot be exercised"
            if 0;    # keep going for the other subtests
        ok(1, "skipping ps-positive identity checks (ps unavailable)");
        return;
    }

    my $runner = named_child('yath-runner');
    ok($cmd->runner_identity_ok($runner, undef), "\$0='yath-runner' => corroborated");

    my $prefixed = named_child('myproj-yath-runner');
    ok($cmd->runner_identity_ok($prefixed, undef), "procname_prefix 'myproj-yath-runner' => corroborated");

    my $plain = named_child('a-plain-sleeper-proc');
    ok(!$cmd->runner_identity_ok($plain, undef), "an unrelated (recycled) process => NOT corroborated");
};

subtest corroborate_runner => sub {
    # (1) garbled / empty PID file: refuse BEFORE any kill() is attempted.
    my $garbled = disco_for('abc');
    like($cmd->corroborate_runner($garbled, 12345, undef), qr/^refuse:/, "garbled PID file => refuse");

    my $empty = disco_for('');
    like($cmd->corroborate_runner($empty, 12345, undef), qr/^refuse:/, "empty PID file => refuse");

    # pid<=1 guard closes the kill($sig,0)-own-pgroup hole.
    my $one = disco_for(1);
    like($cmd->corroborate_runner($one, 1, undef), qr/^refuse:/, "pid 1 => refuse (own-pgroup guard)");

    # Fresh PID file names a DIFFERENT pid than the one we intend to signal => refuse
    # (workdir tie / claim-freshness).
    my $mismatch = disco_for(4242);
    like($cmd->corroborate_runner($mismatch, 9999, undef), qr/^refuse:/, "pid-file/target mismatch => refuse");

    # (2) an ESRCH pid => 'gone' (skip the signal, success).
    my $dead = dead_pid();
    my $dead_disco = disco_for($dead);
    is($cmd->corroborate_runner($dead_disco, $dead, undef), 'gone', "confirmed-dead pid => gone (no signal)");

    return unless $ps_ok;

    # (3a) a LIVE, positively-identified runner => 'ok'.
    my $runner = named_child('yath-runner');
    my $rdisco = disco_for($runner);
    is($cmd->corroborate_runner($rdisco, $runner, undef), 'ok', "live corroborated runner => ok");

    # (3b) THE RECYCLED-PID SAFETY: a live INNOCENT process the PID file happens to
    # name is NOT corroborated => refuse. No signal is ever sent to it.
    my $innocent = named_child('totally-unrelated-daemon');
    my $idisco = disco_for($innocent);
    like(
        $cmd->corroborate_runner($idisco, $innocent, undef),
        qr/^refuse:/,
        "recycled/innocent pid => refuse (never signaled)",
    );

    # (3c) an exact ping-ack pid is identity on its own (even for a plain process,
    # because the ack is the socket owner's self-report of ITS pid).
    is(
        $cmd->corroborate_runner($idisco, $innocent, $innocent),
        'ok',
        "ping-ack pid matching the target => ok (exact identity)",
    );
};

subtest wait_for_runner_exit => sub {
    my $dead = dead_pid();
    my $dead_disco = disco_for($dead);
    my $t0 = time;
    is($cmd->wait_for_runner_exit($dead_disco, $dead, 5), 1, "a dead pid => 1 (gone) immediately");
    ok((time - $t0) < 2, "did not spin waiting on an already-dead pid");

    my $alive = named_child('a-live-child');
    $t0 = time;
    is($cmd->wait_for_runner_exit(undef, $alive, 1), 0, "a live pid => 0 (still alive) at the bounded deadline");
    my $elapsed = time - $t0;
    ok($elapsed >= 0.9 && $elapsed < 5, "the wait was BOUNDED to ~1s, not an unbounded spin (took ${elapsed}s)");
};

done_testing;
