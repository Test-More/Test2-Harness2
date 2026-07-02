use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;
use Time::HiRes qw/sleep time/;
use POSIX ();

use Test2::Util qw/CAN_REALLY_FORK/;
use Test2::Collector::Util::Socket qw/open_unix_listen/;

use App::Yath2::Tester qw/yath/;
use App::Yath2::Util();

# Ticket #121: `yath stop` / `yath kill` must never busy-wait unbounded on a wedged
# runner, and `yath kill` must ESCALATE (TERM -> bounded wait -> KILL) while NEVER
# signalling a pid it cannot corroborate as the runner (the recycled-pid safety).
#
# These drive the REAL `yath stop`/`yath kill` binaries against hand-built runner
# discovery fixtures (a well-known symlink -> workdir/runner.socket + a workdir PID
# file), covering each node of the decision tree. Timeouts are shrunk via env so the
# escalation windows are a few seconds instead of the full 30s+5s.
#
# Fixtures are DOUBLE-FORKED (reparented to init) on purpose: when `yath kill`
# SIGKILLs one, init reaps it so kill(0) reports ESRCH promptly. A plain child of the
# test process would linger as a zombie (kill(0) still true) and defeat the bounded
# wait -- which is a test artifact, not the production case (a real runner is a
# detached daemon reaped by init/its collector).
skip_all "This test is not run under automated testing" if $ENV{AUTOMATED_TESTING};
skip_all "This test requires forking" if $ENV{T2_NO_FORK} || !CAN_REALLY_FORK;

# `ps -o args=` is needed for the ps-identity arm (the LIVE and NOT-LIVE "kill
# terminates a corroborated runner" cases). The recycled/refuse cases do NOT need it
# (a missing ps fail-safes to "not corroborated", which is what those assert anyway).
my $ps_ok = do {
    my $out = '';
    eval { $out = qx{ps -p $$ -o args= 2>/dev/null}; 1 };
    defined($out) && length($out) ? 1 : 0;
};

# find_runner_link is driven off $settings->harness->{persist_dir,project,persist_file}.
{
    package MockHarness;
    sub new          { my ($c, %p) = @_; bless {%p}, $c }
    sub persist_file { $_[0]->{persist_file} }
    sub persist_dir  { $_[0]->{persist_dir} }
    sub project      { $_[0]->{project} }

    package MockSettings;
    sub new     { my ($c, %p) = @_; bless {harness => MockHarness->new(%p)}, $c }
    sub harness { $_[0]->{harness} }
}

# Shrunk escalation windows so a wedged runner is terminated in ~seconds.
my %FAST = (
    YATH_STOP_DEADLINE          => 3,
    YATH_KILL_GRACE             => 1,
    YATH_RUNNER_CONNECT_TIMEOUT => 2,
);

# Grandchildren are reparented to init; the test process cannot waitpid them, so
# cleanup is a best-effort signal (init reaps). local $? so a reaped child's status
# does not become the test's exit code.
my @reap;
END {
    local $?;
    for my $p (@reap) {
        next unless $p;
        kill('KILL', $p) if kill(0, $p);
    }
}

sub link_for {
    my ($persist) = @_;
    my $settings = MockSettings->new(persist_dir => $persist);
    return App::Yath2::Util::find_runner_link($settings, vivify => 1);
}

# The run/stop/kill base reads the runner's workdir/settings.json during init (to
# inherit runner settings). A real runner writes it at start; a fixture must provide
# an (empty) one or init dies before the decision tree is ever reached.
sub prep_workdir {
    my ($workdir) = @_;
    open(my $fh, '>', File::Spec->catfile($workdir, 'settings.json')) or die "settings.json: $!";
    print $fh "{}\n";
    close($fh);
    return $workdir;
}

# Double-fork a long-lived fixture "runner". Returns the grandchild pid (reparented
# to init). The grandchild optionally binds workdir/runner.socket (LIVE), sets $0
# (identity), and either ignores TERM or writes a flag file on TERM (to PROVE whether
# a signal was delivered). It writes workdir/PID and workdir/READY, then sleeps.
sub spawn_fixture {
    my %p = @_;
    my $workdir = $p{workdir};

    pipe(my $r, my $w) or die "pipe: $!";
    my $mid = fork();
    die "fork: $!" unless defined $mid;

    if (!$mid) {
        close($r);
        my $gc = fork();
        if (!defined $gc) { syswrite($w, "ERR\n"); POSIX::_exit(1) }

        if ($gc) {
            # middle process: report the grandchild pid, then exit so the grandchild
            # is reparented to init.
            syswrite($w, "$gc\n");
            close($w);
            POSIX::_exit(0);
        }

        # grandchild: the fixture "runner".
        close($w);
        my $listen;
        $listen = open_unix_listen(File::Spec->catfile($workdir, 'runner.socket')) if $p{live};

        $0 = $p{name} if defined $p{name};

        if ($p{ignore_term}) {
            $SIG{TERM} = 'IGNORE';
        }
        elsif ($p{flag}) {
            my $flag = $p{flag};
            $SIG{TERM} = sub {
                if (open(my $f, '>', $flag)) { close($f) }
                POSIX::_exit(0);
            };
        }

        open(my $pf, '>', File::Spec->catfile($workdir, 'PID')) or POSIX::_exit(1);
        print $pf "$$\n";
        close($pf);

        open(my $rf, '>', File::Spec->catfile($workdir, 'READY')) or POSIX::_exit(1);
        close($rf);

        sleep 1 while 1;
        POSIX::_exit(0);
    }

    close($w);
    waitpid($mid, 0);    # reap the middle immediately

    my $line = '';
    sysread($r, $line, 64);
    close($r);
    chomp($line);
    die "fixture spawn failed (got '$line')\n" unless $line =~ /^(\d+)$/;

    my $pid = $1;
    push @reap => $pid;
    return $pid;
}

sub wait_ready {
    my ($workdir) = @_;
    my $ready    = File::Spec->catfile($workdir, 'READY');
    my $deadline = time + 30;
    until (-e $ready) {
        die "fixture never became ready\n" if time > $deadline;
        sleep 0.02;
    }
}

# Bind + close a listener so the socket inode exists but connect() gets ECONNREFUSED
# (the "wedged" / not-live shape: a socket file with no live listener).
sub make_refused_socket {
    my ($workdir) = @_;
    my $sock = File::Spec->catfile($workdir, 'runner.socket');
    my $l = open_unix_listen($sock);
    close($l);
    return $sock;
}

# ---------------------------------------------------------------------------
# LIVE + TERM-ignoring runner: `yath kill` does not die on the truncate croak,
# escalates through TERM to SIGKILL within the bounded window, exits 1, and cleans
# the link + workdir. (ticket T1)
# ---------------------------------------------------------------------------
SKIP: {
    skip "requires ps -o args= for the identity arm", 1 unless $ps_ok;

    my $persist = tempdir(CLEANUP => 1);
    my $workdir = prep_workdir(tempdir(CLEANUP => 1));

    my $pid  = spawn_fixture(workdir => $workdir, name => 'yath-runner', live => 1, ignore_term => 1);
    wait_ready($workdir);
    my $link = link_for($persist);
    symlink(File::Spec->catfile($workdir, 'runner.socket'), $link) or die "symlink: $!";

    my $t0 = time;
    yath(
        command => 'kill',
        env     => {%FAST, YATH_PERSISTENCE_DIR => $persist},
        test    => sub {
            my $out = shift;
            is($out->{exit} >> 8, 1, "kill exits 1 (forced termination, nonzero-cleanly)");
            like($out->{output}, qr/Runner killed/, "kill reports the runner was killed (escalated to SIGKILL)");
        },
    );
    my $elapsed = time - $t0;

    ok(!kill(0, $pid), "LIVE TERM-ignoring runner was terminated by kill");
    ok($elapsed < 60, "kill was BOUNDED (took ${elapsed}s), not an unbounded spin");
    ok(!-l $link, "the discovery link was cleaned after a confirmed kill");
    ok(!-d $workdir, "the workdir was removed after a confirmed kill");
}

# ---------------------------------------------------------------------------
# NOT-LIVE (refused socket) + TERM-ignoring, corroborated runner: `yath kill` skips
# the socket, escalates straight from the PID file, SIGKILLs it, exits 1, cleans.
# ---------------------------------------------------------------------------
SKIP: {
    skip "requires ps -o args= for the identity arm", 1 unless $ps_ok;

    my $persist = tempdir(CLEANUP => 1);
    my $workdir = prep_workdir(tempdir(CLEANUP => 1));

    my $pid = spawn_fixture(workdir => $workdir, name => 'yath-runner', live => 0, ignore_term => 1);
    wait_ready($workdir);
    make_refused_socket($workdir);
    my $link = link_for($persist);
    symlink(File::Spec->catfile($workdir, 'runner.socket'), $link) or die "symlink: $!";

    yath(
        command => 'kill',
        env     => {%FAST, YATH_PERSISTENCE_DIR => $persist},
        test    => sub {
            my $out = shift;
            is($out->{exit} >> 8, 1, "kill exits 1 for a wedged (not-live) corroborated runner");
            like($out->{output}, qr/Runner killed/, "kill terminated a wedged (not-live) corroborated runner");
        },
    );

    ok(!kill(0, $pid), "NOT-LIVE wedged runner was terminated by kill");
    ok(!-l $link,   "link cleaned");
    ok(!-d $workdir, "workdir removed");
}

# ---------------------------------------------------------------------------
# RECYCLED PID: the workdir PID file names a live INNOCENT process (a crashed
# runner's pid recycled). `yath kill` must exit 2 with a diagnostic, send NO signal
# to that pid, and leave the link + workdir INTACT. (ticket T3 -- the crux safety)
# ---------------------------------------------------------------------------
{
    my $persist = tempdir(CLEANUP => 1);
    my $workdir = prep_workdir(tempdir(CLEANUP => 1));
    my $flag    = File::Spec->catfile($workdir, 'GOT_TERM');

    my $pid = spawn_fixture(workdir => $workdir, name => 'innocent-bystander-proc', live => 0, flag => $flag);
    wait_ready($workdir);
    make_refused_socket($workdir);
    my $link = link_for($persist);
    symlink(File::Spec->catfile($workdir, 'runner.socket'), $link) or die "symlink: $!";

    yath(
        command => 'kill',
        env     => {%FAST, YATH_PERSISTENCE_DIR => $persist},
        test    => sub {
            my $out = shift;
            is($out->{exit} >> 8, 2, "kill exits 2 (diagnostic) on an uncorroborated pid");
            like($out->{output}, qr/Refusing to kill/, "kill refuses an uncorroborated (recycled) pid");
        },
    );

    ok(kill(0, $pid), "the innocent recycled-pid process is STILL ALIVE (never signalled)");
    ok(!-e $flag,     "no TERM was ever delivered to the innocent process");
    ok(-l $link,      "the discovery link was left INTACT (nothing cleaned on refusal)");
    ok(-d $workdir,   "the workdir was left INTACT (nothing cleaned on refusal)");

    kill('KILL', $pid) if kill(0, $pid);
}

# ---------------------------------------------------------------------------
# STOP on a NOT-LIVE (wedged) runner: exit 1, send NO signal, leave the link intact
# (stop never escalates -- that is kill's job). (ticket T4)
# ---------------------------------------------------------------------------
{
    my $persist = tempdir(CLEANUP => 1);
    my $workdir = prep_workdir(tempdir(CLEANUP => 1));
    my $flag    = File::Spec->catfile($workdir, 'GOT_TERM');

    my $pid = spawn_fixture(workdir => $workdir, name => 'yath-runner', live => 0, flag => $flag);
    wait_ready($workdir);
    make_refused_socket($workdir);
    my $link = link_for($persist);
    symlink(File::Spec->catfile($workdir, 'runner.socket'), $link) or die "symlink: $!";

    my $t0 = time;
    yath(
        command => 'stop',
        env     => {%FAST, YATH_PERSISTENCE_DIR => $persist},
        test    => sub {
            my $out = shift;
            is($out->{exit} >> 8, 1, "stop exits 1 on a wedged runner");
            like($out->{output}, qr/not responding/, "stop reports the wedged runner and points at `yath kill`");
        },
    );
    my $elapsed = time - $t0;

    ok($elapsed < 60,  "stop did not spin on the wedged runner (took ${elapsed}s)");
    ok(kill(0, $pid),  "stop sent NO signal to the wedged runner");
    ok(!-e $flag,      "no TERM was delivered by stop (stop never escalates)");
    ok(-l $link,       "stop left the link intact so `yath kill` can still find it");

    kill('KILL', $pid) if kill(0, $pid);
}

# ---------------------------------------------------------------------------
# DEAD runner (PID file names an ESRCH pid, socket refused): both stop and kill exit
# 0 with "already dead" and clean up the remains. (ticket T6)
# ---------------------------------------------------------------------------
for my $cmd (qw/stop kill/) {
    my $persist = tempdir(CLEANUP => 1);
    my $workdir = prep_workdir(tempdir(CLEANUP => 1));

    # A pid guaranteed dead (fork + reap => ESRCH).
    my $dead = fork();
    die "fork: $!" unless defined $dead;
    if (!$dead) { POSIX::_exit(0) }
    waitpid($dead, 0);

    open(my $pf, '>', File::Spec->catfile($workdir, 'PID')) or die "PID: $!";
    print $pf "$dead\n";
    close($pf);
    make_refused_socket($workdir);

    my $link = link_for($persist);
    symlink(File::Spec->catfile($workdir, 'runner.socket'), $link) or die "symlink: $!";

    yath(
        command => $cmd,
        env     => {%FAST, YATH_PERSISTENCE_DIR => $persist},
        exit    => 0,
        test    => sub {
            my $out = shift;
            like($out->{output}, qr/already dead/, "$cmd on a dead runner reports it was already dead");
        },
    );

    ok(!-l $link,    "$cmd cleaned the stale link for the dead runner");
    ok(!-d $workdir, "$cmd removed the workdir for the dead runner");
}

# ---------------------------------------------------------------------------
# HEALTHY stop is UNCHANGED: a real persistent runner started + stopped exits 0 with
# "Runner stopped", no added latency, no signal escalation. (ticket T5)
# ---------------------------------------------------------------------------
{
    yath(command => 'start', exit => 0);

    my $t0 = time;
    yath(
        command => 'stop',
        exit    => 0,
        test    => sub {
            my $out = shift;
            like($out->{output}, qr/Runner stopped/, "healthy stop still reports 'Runner stopped'");
        },
    );
    my $elapsed = time - $t0;
    ok($elapsed < 60, "healthy stop returned promptly (took ${elapsed}s) -- timing unchanged");
}

done_testing;
