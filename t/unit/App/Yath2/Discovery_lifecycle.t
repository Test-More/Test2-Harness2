use Test2::V0 -target => 'App::Yath2::Discovery';
use Test2::Tools::Spec;

use File::Temp qw/tempdir/;
use File::Spec;
use Time::HiRes qw/time/;

use Socket qw/PF_UNIX SOCK_STREAM sockaddr_un/;
use Fcntl qw/F_GETFL F_SETFL O_NONBLOCK/;

use Test2::Collector::Util::Socket qw/open_unix_listen/;
use Test2::Harness2::Util qw/clean_path publish_discovery_link/;

use App::Yath2::Discovery;

# Regression coverage for ticket #145 (Discovery/start lifecycle bundle):
#   * probe() taxonomy: only an UNAMBIGUOUSLY-dead link is ever cleaned; every
#     not-live outcome (boot window, wedged, another user's runner, ...) keeps it.
#   * the not-live discovery object #121's escalation consumes.
#   * the concurrent-probe race closure: a cleaner must never unlink a link that a
#     live (or freshly-republished) runner owns.
#   * write_link_atomic / publish: a reader never sees a torn or missing link.
#   * clean_if_mine's owner-side identity + successor-liveness re-check.
#   * probe() returns within a bounded window against a non-accepting listener.

# ---------------------------------------------------------------------------
# A minimal Getopt::Yath::Settings stand-in (find_runner_link only touches
# ->harness and a few accessors).
{
    package MockHarness;
    sub new { my ($c, %p) = @_; return bless {%p}, $c }
    sub persist_file { $_[0]->{persist_file} }
    sub persist_dir  { $_[0]->{persist_dir} }
    sub project      { $_[0]->{project} }

    package MockSettings;
    sub new { my ($c, %p) = @_; return bless {harness => MockHarness->new(%p)}, $c }
    sub harness { $_[0]->{harness} }
}

my $PROJECT_SEQ = 0;

# A settings object pinned to a fresh persist dir plus the symlink path it picks.
sub link_in_persist_dir {
    my $persist  = tempdir(CLEANUP => 1);
    my $settings = MockSettings->new(project => "Disco-Life-" . ++$PROJECT_SEQ, persist_dir => $persist);
    my $link     = App::Yath2::Util::find_runner_link($settings, vivify => 1);
    return ($persist, $link, $settings);
}

# Stand up a runner-style workdir. Options:
#   no_socket => 1   do not bind runner.socket
#   pid       => N   write this pid to the workdir PID file (default $$ = alive)
#   no_pid    => 1   do not write a PID file
#   file_socket => 1 put a REGULAR FILE at runner.socket (not a socket)
# Returns ($workdir, $listen) -- keep $listen in scope to hold the socket bound.
sub make_workdir {
    my (%params) = @_;
    my $workdir = clean_path(tempdir(CLEANUP => 1));
    my $sock_path = File::Spec->catfile($workdir, 'runner.socket');

    my $listen;
    if ($params{file_socket}) {
        open(my $fh, '>', $sock_path) or die "write fake socket: $!";
        print $fh "not a socket";
        close($fh);
    }
    elsif (!$params{no_socket}) {
        $listen = open_unix_listen($sock_path);
    }

    unless ($params{no_pid}) {
        my $pidfile = File::Spec->catfile($workdir, 'PID');
        open(my $fh, '>', $pidfile) or die "write PID: $!";
        print $fh (exists $params{pid} ? $params{pid} : $$);
        close($fh);
    }

    return ($workdir, $listen);
}

# A pid guaranteed dead (fork/exit/reap) so kill(0) => ESRCH.
sub dead_pid {
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) { exit 0 }
    waitpid($pid, 0);
    return $pid;
}

# Build a Discovery over a workdir's runner.socket via a symlink at $link.
sub disco_for {
    my ($workdir, $link) = @_;
    my $target = File::Spec->catfile($workdir, 'runner.socket');
    unlink($link) if -l $link;
    symlink($target, $link) or die "symlink: $!";
    return App::Yath2::Discovery->new(link => $link);
}

# ---------------------------------------------------------------------------
tests probe_taxonomy => sub {
    # live: bound socket + alive pid.
    {
        my ($wd, $listen) = make_workdir(pid => $$);
        my ($p, $link) = link_in_persist_dir();
        my $rec = disco_for($wd, $link)->probe;
        is($rec->{state}, 'live', "bound socket + alive pid => live");
    }

    # dangling: the WORKDIR itself is gone => unambiguously DEAD.
    {
        my ($p, $link) = link_in_persist_dir();
        my $gone = File::Spec->catfile(File::Spec->catdir(tempdir(CLEANUP => 1), 'nope'), 'runner.socket');
        symlink($gone, $link) or die "symlink: $!";
        my $rec = App::Yath2::Discovery->new(link => $link)->probe;
        is($rec->{state}, 'dead', "target workdir missing => dead");
    }

    # T missing, workdir present, pid ALIVE => the boot window / wedged: NOT-LIVE.
    {
        my ($wd, undef) = make_workdir(no_socket => 1, pid => $$);
        my ($p, $link) = link_in_persist_dir();
        my $rec = disco_for($wd, $link)->probe;
        is($rec->{state},  'not_live', "socket not yet bound + alive pid => not_live");
        is($rec->{reason}, 'boot',     "  ... reason boot");
    }

    # T missing, workdir present, pid ESRCH => confirmed dead.
    {
        my ($wd, undef) = make_workdir(no_socket => 1, pid => dead_pid());
        my ($p, $link) = link_in_persist_dir();
        my $rec = disco_for($wd, $link)->probe;
        is($rec->{state}, 'dead', "socket missing + dead pid => dead");
    }

    # socket file present but connect refused (listener closed), pid ALIVE => wedged.
    {
        my ($wd, $listen) = make_workdir(pid => $$);
        close($listen);
        my ($p, $link) = link_in_persist_dir();
        my $rec = disco_for($wd, $link)->probe;
        is($rec->{state},  'not_live', "ECONNREFUSED + alive pid => not_live");
        is($rec->{reason}, 'wedged',   "  ... reason wedged");
    }

    # socket file present but refused, pid ESRCH => confirmed dead orphan socket.
    {
        my ($wd, $listen) = make_workdir(pid => dead_pid());
        close($listen);
        my ($p, $link) = link_in_persist_dir();
        my $rec = disco_for($wd, $link)->probe;
        is($rec->{state}, 'dead', "ECONNREFUSED + dead pid => dead");
    }

    # target exists but is NOT a socket (a regular file) => never proof of death.
    {
        my ($wd, undef) = make_workdir(file_socket => 1, pid => $$);
        my ($p, $link) = link_in_persist_dir();
        my $rec = disco_for($wd, $link)->probe;
        is($rec->{state},  'not_live', "non-socket target => not_live");
        is($rec->{reason}, 'boot',     "  ... reason boot");
    }

    # a REGULAR FILE at the link path (not a symlink) => foreign, never touched.
    {
        my ($p, $link) = link_in_persist_dir();
        open(my $fh, '>', $link) or die "write blocker: $!";
        print $fh "a real file";
        close($fh);
        my $rec = App::Yath2::Discovery->new(link => $link)->probe;
        is($rec->{state},  'not_live', "regular file at link => not_live");
        is($rec->{reason}, 'foreign',  "  ... reason foreign");
        ok(-e $link && !-l $link, "the foreign file is left untouched");
    }
};

tests find_keeps_not_live_and_exposes_the_object => sub {
    # A wedged-but-alive runner: socket file on disk but not accepting, pid alive.
    my ($wd, $listen) = make_workdir(pid => $$);
    close($listen);
    my $sockpath = File::Spec->catfile($wd, 'runner.socket');
    ok(-S $sockpath, "socket file survives the listener close");

    my ($p, $link, $settings) = link_in_persist_dir();
    symlink($sockpath, $link) or die "symlink: $!";

    # default find() keeps the live-or-nothing contract, but MUST NOT clean it.
    my $default = App::Yath2::Discovery->find($settings);
    is($default, undef, "default find() returns nothing for a not-live runner");
    ok(-l $link, "  ... but leaves the link (a wedged runner stays discoverable)");

    # any_state find() returns the object in the not-live state -- exactly the fields
    # #121's signal-based escalation consumes, all available with the socket dead.
    my $found = App::Yath2::Discovery->find($settings, any_state => 1);
    isa_ok($found, [$CLASS], "any_state returns the wedged runner object");
    is($found->state,    'not_live', "state is not_live");
    is($found->reason,   'wedged',   "reason is wedged");
    is($found->pid,      "$$",       "pid resolved from the workdir PID file");
    is($found->pid_live, 1,          "pid_live reports the process is alive");
    is($found->pid_file, File::Spec->catfile($wd, 'PID'), "pid_file is workdir/PID (pure path math)");
    is($found->workdir,  $wd,        "workdir is pure path math off the link target");
    ok(-l $link, "any_state find() also left the link in place");
};

tests concurrent_poll_during_boot_keeps_fresh_link => sub {
    # A booted runner: PID alive, socket bound, link published last (as the runner
    # itself now does). A poll storm of concurrent find()s (yath status/which racing
    # someone else's boot) must NEVER clean a live runner's link.
    my ($wd, $listen) = make_workdir(pid => $$);
    my ($p, $link, $settings) = link_in_persist_dir();
    publish_discovery_link(File::Spec->catfile($wd, 'runner.socket'), $link);

    my @kids;
    for (1 .. 5) {
        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if (!$pid) {
            App::Yath2::Discovery->find($settings) for 1 .. 40;
            exit 0;
        }
        push @kids, $pid;
    }
    App::Yath2::Discovery->find($settings) for 1 .. 40;
    waitpid($_, 0) for @kids;

    ok(-l $link, "concurrent find() polling never unlinked the fresh live link");
    ok(App::Yath2::Discovery->new(link => $link)->resolves, "the link still resolves LIVE after the poll storm");
};

tests clean_race_pinned_workdir_identical_target => sub {
    # The crux TOCTOU: a cleaner probes the OLD (dead) runner as dead, but before it
    # unlinks, a NEW runner restarts in the SAME pinned workdir -- writing its live
    # PID and re-binding the socket, republishing the IDENTICAL target string. The
    # cleaner's locked deadness RE-CHECK must flip to not-live and abort, so the fresh
    # link survives.
    my ($wd, undef) = make_workdir(no_socket => 1, pid => dead_pid());
    my ($p, $link) = link_in_persist_dir();
    my $disco = disco_for($wd, $link);

    my $stale = $disco->probe;
    is($stale->{state}, 'dead', "the old runner probes dead");

    # The pinned-workdir successor comes up: live pid + bound socket (same target).
    my $pidfile = File::Spec->catfile($wd, 'PID');
    open(my $fh, '>', $pidfile) or die "write PID: $!"; print $fh $$; close($fh);
    my $listen = open_unix_listen(File::Spec->catfile($wd, 'runner.socket'));

    # The cleaner now fires its deferred clean using the STALE dead probe.
    $disco->clean_if_owned($stale);

    ok(-l $link, "clean_if_owned aborted: the live pinned-workdir successor kept its link");
    ok(App::Yath2::Discovery->new(link => $link)->resolves, "the republished link resolves LIVE");
};

tests clean_race_republished_elsewhere => sub {
    # A cleaner probes a dead link (target A), but the link is then repointed at a
    # DIFFERENT live runner (target B). The readlink-compare step must abort the
    # clean (the target no longer matches what we probed).
    my ($a, undef) = make_workdir(no_socket => 1, pid => dead_pid());
    my ($p, $link) = link_in_persist_dir();
    my $disco = disco_for($a, $link);
    my $stale = $disco->probe;
    is($stale->{state}, 'dead', "runner A probes dead");

    my ($b, $listen_b) = make_workdir(pid => $$);
    my $b_socket = File::Spec->catfile($b, 'runner.socket');
    publish_discovery_link($b_socket, $link);    # repoint L -> B

    $disco->clean_if_owned($stale);

    ok(-l $link, "clean_if_owned aborted: the link was republished elsewhere");
    is(clean_path(readlink($link)), clean_path($b_socket), "the newly-published (live) link survived intact");
};

tests atomic_publish_never_torn => sub {
    # Hammer readlink from a child while the parent republishes between two targets.
    # rename(2) replaces the name atomically, so the reader must always observe one
    # of the two targets and NEVER a missing/half-published link.
    my ($p, $link) = link_in_persist_dir();
    my $t1 = File::Spec->catfile(tempdir(CLEANUP => 1), 'runner.socket');
    my $t2 = File::Spec->catfile(tempdir(CLEANUP => 1), 'runner.socket');

    publish_discovery_link($t1, $link);    # exist before the reader starts

    my $reader = fork();
    die "fork: $!" unless defined $reader;
    if (!$reader) {
        for (1 .. 4000) {
            my $t = readlink($link);
            exit 1 unless defined $t;               # ENOENT: a torn/missing link
            exit 2 unless $t eq $t1 || $t eq $t2;   # a partial target
        }
        exit 0;
    }

    for (1 .. 4000) {
        publish_discovery_link(($_ % 2) ? $t2 : $t1, $link);
    }
    waitpid($reader, 0);
    my $code = $? >> 8;

    is($code, 0, "reader always saw the old-or-new target across N atomic republishes");
    ok(-l $link, "link still present after the republish storm");
};

tests clean_if_mine_owner_protocol => sub {
    # Owner-side removal (runner exit guard / stop / kill): only remove the link when
    # it still points at OUR socket and no LIVE successor claimed the pinned workdir.

    # A live successor (pid $$) now owns the workdir -> the old owner's exit guard
    # must leave the link.
    {
        my ($wd, $listen) = make_workdir(pid => $$);
        my ($p, $link) = link_in_persist_dir();
        my $socket = File::Spec->catfile($wd, 'runner.socket');
        symlink($socket, $link) or die "symlink: $!";

        my $old_pid = dead_pid();    # our (now-gone) runner, a DIFFERENT pid
        App::Yath2::Discovery->new(link => $link)->clean_if_mine($socket, $old_pid);
        ok(-l $link, "exit guard left the link: a live successor (different pid) owns the workdir");
    }

    # No successor (the workdir PID is still ours) -> the guard removes its own link.
    {
        my ($wd, undef) = make_workdir(no_socket => 1, pid => $$);
        my ($p, $link) = link_in_persist_dir();
        my $socket = File::Spec->catfile($wd, 'runner.socket');
        symlink($socket, $link) or die "symlink: $!";

        App::Yath2::Discovery->new(link => $link)->clean_if_mine($socket, $$);
        ok(!-l $link, "exit guard removed its own link when the workdir PID is still ours");
    }

    # The link points at a DIFFERENT socket -> never ours to remove.
    {
        my ($wd, undef) = make_workdir(no_socket => 1, pid => $$);
        my ($p, $link) = link_in_persist_dir();
        my $other = File::Spec->catfile($wd, 'runner.socket');
        symlink($other, $link) or die "symlink: $!";

        my $mine = File::Spec->catfile(tempdir(CLEANUP => 1), 'runner.socket');
        App::Yath2::Discovery->new(link => $link)->clean_if_mine($mine, $$);
        ok(-l $link, "clean_if_mine left a link that points at someone else's socket");
    }
};

tests probe_is_bounded_never_hangs => sub {
    # A live listen fd whose accept loop never runs (a wedged runner): a BLOCKING unix
    # connect would hang in unix_wait_for_peer once the backlog fills. probe() uses a
    # bounded non-blocking connect, so it must return quickly and NEVER classify such a
    # runner as dead (its link must survive).
    my $workdir = clean_path(tempdir(CLEANUP => 1));
    my $sock_path = File::Spec->catfile($workdir, 'runner.socket');

    # A listener with a tiny backlog, deliberately never accept()ed.
    CORE::socket(my $listen, PF_UNIX, SOCK_STREAM, 0) or die "socket: $!";
    bind($listen, sockaddr_un($sock_path)) or die "bind: $!";
    listen($listen, 1) or die "listen: $!";

    # Fill the accept queue with NON-BLOCKING pending connects (blocking ones would
    # hang the test itself -- the very bug). Hold them open.
    my @pending;
    for (1 .. 12) {
        CORE::socket(my $c, PF_UNIX, SOCK_STREAM, 0) or last;
        my $fl = fcntl($c, F_GETFL, 0);
        fcntl($c, F_SETFL, ($fl // 0) | O_NONBLOCK);
        connect($c, sockaddr_un($sock_path));    # EINPROGRESS/EAGAIN; do not block
        push @pending, $c;
    }

    my $pidfile = File::Spec->catfile($workdir, 'PID');
    open(my $fh, '>', $pidfile) or die "write PID: $!"; print $fh $$; close($fh);

    my ($pp, $link) = link_in_persist_dir();
    symlink($sock_path, $link) or die "symlink: $!";
    my $disco = App::Yath2::Discovery->new(link => $link);

    my $start = time();
    my $rec   = $disco->probe;
    my $elapsed = time() - $start;

    ok($elapsed < 2, "probe() returned within a bounded window (${elapsed}s), no hang");
    isnt($rec->{state}, 'dead', "a live-but-unresponsive listener is never classified dead");
    ok(-l $link, "  ... so its discovery link is kept");
    # When the backlog actually rejected our probe connect, it is reported as backlog.
    is($rec->{reason}, 'backlog', "reason is backlog") if $rec->{state} eq 'not_live';
};

done_testing;
