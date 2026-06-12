use Test2::V0;
use Config;
use POSIX qw/_exit/;
use Time::HiRes qw/usleep/;

use Test2::Harness2::Util::IPC qw/list_direct_children start_process pid_is_running set_procname swap_io/;

# Pure parsers -- these are the heart of the cross-platform logic and
# can be exercised without touching /proc or forking.

subtest '_parse_proc_status_ppid: Linux multi-line format' => sub {
    my $content = <<"EOF";
Name:\tperl
Umask:\t0022
State:\tS (sleeping)
Tgid:\t4321
Ngid:\t0
Pid:\t4321
PPid:\t1234
TracerPid:\t0
Uid:\t1000\t1000\t1000\t1000
Gid:\t1000\t1000\t1000\t1000
EOF
    is(
        Test2::Harness2::Util::IPC::_parse_proc_status_ppid($content),
        1234,
        'extracts PPid: line',
    );
};

subtest '_parse_proc_status_ppid: Uid line does not spoof ppid' => sub {
    # Regression guard: a naive positional regex would read Uid:'s
    # second column ("1000") as ppid. The Linux branch anchors on
    # "PPid:" so it must win even though the Uid: line appears first
    # when scanned positionally.
    my $content = <<"EOF";
Uid:\t1000\t1000\t1000\t1000
PPid:\t4242
EOF
    is(
        Test2::Harness2::Util::IPC::_parse_proc_status_ppid($content),
        4242,
        'prefers PPid: over Uid positional spoof',
    );
};

subtest '_parse_proc_status_ppid: FreeBSD single-line format' => sub {
    # From procfs(5): comm pid ppid pgid sid maj,min ctty,sldr start ...
    my $content = "perl 4321 1234 4321 4321 5,1 noctty,noldr 1600000000,0 0,0 0,0 - 1000 1000 1000,1000 -\n";
    is(
        Test2::Harness2::Util::IPC::_parse_proc_status_ppid($content),
        1234,
        'extracts ppid from BSD positional layout',
    );
};

subtest '_parse_proc_status_ppid: DragonFlyBSD single-line format' => sub {
    # DragonFlyBSD procfs exposes the same shape as FreeBSD's. Using a
    # comm with punctuation confirms we treat the first column as an
    # opaque token rather than constraining it to [A-Za-z_].
    my $content = "my-test.t 9999 4321 9999 9999 0,0 noctty,noldr 1700000000,0 0,0 0,0 - 1000 1000 1000,1000 -\n";
    is(
        Test2::Harness2::Util::IPC::_parse_proc_status_ppid($content),
        4321,
        'handles non-alphanumeric comm field',
    );
};

subtest '_parse_proc_status_ppid: junk and empty inputs' => sub {
    is(Test2::Harness2::Util::IPC::_parse_proc_status_ppid(undef), undef, 'undef content');
    is(Test2::Harness2::Util::IPC::_parse_proc_status_ppid(''),    undef, 'empty content');
    is(
        Test2::Harness2::Util::IPC::_parse_proc_status_ppid("completely\nunrelated\ngibberish\n"),
        undef,
        'no ppid found',
    );
};

subtest '_parse_ps_pid_ppid: filters by parent and excludes self' => sub {
    my $output = <<'EOF';
    1     0
  100     1
  200   100
  300   100
  400   200
EOF
    my @kids = Test2::Harness2::Util::IPC::_parse_ps_pid_ppid($output, 100);
    is(
        [sort { $a <=> $b } @kids],
        [200, 300],
        'only direct children of 100',
    );
};

subtest '_parse_ps_pid_ppid: ignores parent == self' => sub {
    # Never emit the parent pid itself, even if ps somehow reports
    # <pid> <pid> for a corner case.
    my $output = "42 42\n100 42\n";
    is(
        [Test2::Harness2::Util::IPC::_parse_ps_pid_ppid($output, 42)],
        [100],
        'skips pid == parent',
    );
};

subtest '_parse_ps_pid_ppid: malformed lines are skipped' => sub {
    my $output = "PID  PPID\nheader garbage\n  55    10\n\nwhatever\n";
    is(
        [Test2::Harness2::Util::IPC::_parse_ps_pid_ppid($output, 10)],
        [55],
        'only well-formed numeric rows contribute',
    );
};

subtest '_parse_ps_pid_ppid: empty or undef input' => sub {
    is([Test2::Harness2::Util::IPC::_parse_ps_pid_ppid('',    1)], [], 'empty');
    is([Test2::Harness2::Util::IPC::_parse_ps_pid_ppid(undef, 1)], [], 'undef');
};

# Integration with the live process -- skip where the platform cannot
# support the test (no fork) or where procfs/ps are unavailable.

my $can_fork = $Config{d_fork};

subtest 'list_direct_children($$) finds a forked child' => sub {
    skip_all "fork required" unless $can_fork;

    pipe(my $r, my $w) or die "pipe: $!";
    my $kid = fork // die "fork: $!";
    if (!$kid) {
        close $r;
        # Signal we're up, then park until parent kills us.
        syswrite($w, "1");
        sleep 30;
        _exit(0);
    }
    close $w;

    # Wait for the child to confirm it is running before inspecting
    # the process table -- avoids a race on slow CI.
    my $buf;
    sysread($r, $buf, 1);
    close $r;

    my @kids = list_direct_children($$);
    ok(grep({ $_ == $kid } @kids), "child pid $kid found among " . join(',', @kids));
    ok(!grep({ $_ == $$ } @kids),  'self not included');

    kill 'TERM', $kid;
    waitpid($kid, 0);
};

subtest '_list_direct_children_proc on Linux-shaped procfs' => sub {
    skip_all "fork required"              unless $can_fork;
    skip_all "/proc/\$\$/status required" unless -e "/proc/$$/status";

    my $kid = fork // die "fork: $!";
    if (!$kid) {
        sleep 30;
        _exit(0);
    }

    # Poll until the child shows up; forking is synchronous but procfs
    # population can lag slightly.
    my @kids;
    for (1 .. 50) {
        @kids = Test2::Harness2::Util::IPC::_list_direct_children_proc($$);
        last if grep { $_ == $kid } @kids;
        usleep(10_000);
    }

    ok(grep({ $_ == $kid } @kids), "proc finds forked child $kid");

    kill 'TERM', $kid;
    waitpid($kid, 0);
};

subtest '_list_direct_children_ps when ps is available' => sub {
    skip_all "fork required" unless $can_fork;
    my $ps_ok = do {
        my $fh;
        open($fh, '-|', 'ps -e -o pid= -o ppid= 2>/dev/null')
            or open($fh, '-|', 'ps -A -o pid= -o ppid= 2>/dev/null');
        my $any = $fh ? do { local $/; <$fh> } : '';
        length($any // '') ? 1 : 0;
    };
    skip_all "ps unavailable" unless $ps_ok;

    my $kid = fork // die "fork: $!";
    if (!$kid) {
        sleep 30;
        _exit(0);
    }

    my @kids;
    for (1 .. 50) {
        @kids = Test2::Harness2::Util::IPC::_list_direct_children_ps($$);
        last if grep { $_ == $kid } @kids;
        usleep(10_000);
    }

    ok(grep({ $_ == $kid } @kids), "ps finds forked child $kid");

    kill 'TERM', $kid;
    waitpid($kid, 0);
};

subtest 'list_direct_children returns empty for a pid with no children' => sub {
    # pid 1 is owned by init and always exists, but we assume its
    # direct-child set does not include $$ itself. More importantly, we
    # pass an obviously-invalid pid and expect an empty list rather than
    # garbage -- the enumeration should filter by ppid strictly.
    my @kids = list_direct_children(999_999_999);
    is(\@kids, [], 'implausible parent yields no children');
};

subtest '_list_direct_children_ps does not report its own ps child' => sub {
    # The ps fallback forks to run ps; during that short window ps is
    # our direct child and lists itself in its own output. Without a
    # post-parse filter it would return a transient pid that is
    # already gone by the time the caller sees it -- catastrophic for
    # callers that re-enumerate each iteration of a kill/reap loop.
    my $ps_ok = do {
        my $fh;
        open($fh, '-|', 'ps -A -o pid= -o ppid= 2>/dev/null')
            or open($fh, '-|', 'ps -e -o pid= -o ppid= 2>/dev/null');
        my $any = $fh ? do { local $/; <$fh> } : '';
        length($any // '') ? 1 : 0;
    };
    skip_all "ps unavailable" unless $ps_ok;

    # No fork -- $$ has no children of its own. A correct ps branch
    # must return an empty list; a naive one would include its own
    # ps pid.
    for (1 .. 5) {
        my @kids = Test2::Harness2::Util::IPC::_list_direct_children_ps($$);
        is(\@kids, [], "iteration $_: ps fallback returned no phantom pids");
    }
};

subtest 'start_process: basic fork+exec' => sub {
    skip_all "fork required" unless $Config{d_fork};

    pipe(my $r, my $w) or die "pipe: $!";

    my $pid = start_process([$^X, '-e', 'syswrite(STDOUT, "ok"); exit 0'], sub {
        close $r;
        open(STDOUT, '>&', $w) or _exit(1);
    });

    close $w;
    ok($pid > 0, "start_process returns a positive pid ($pid)");

    my $buf = '';
    sysread($r, $buf, 16);
    close $r;

    is($buf, 'ok', 'child wrote expected output, confirming exec ran');

    waitpid($pid, 0);
    is($? >> 8, 0, 'child exited 0');
};

subtest 'start_process: post_fork callback fires in child only' => sub {
    skip_all "fork required" unless $Config{d_fork};

    my $fired_in_parent = 0;

    pipe(my $r, my $w) or die "pipe: $!";
    my $pid = start_process([$^X, '-e', 'exit 0'], sub {
        # This runs only in the child; parent returns immediately after fork
        close $r;
        syswrite($w, "child");
        close $w;
    });

    close $w;
    my $buf = '';
    sysread($r, $buf, 16);
    close $r;

    is($buf, 'child',        'post_fork callback ran in child');
    is($fired_in_parent, 0,  'callback did not set parent variable');

    waitpid($pid, 0);
};

subtest 'start_process: dies on empty command' => sub {
    like(
        dies { start_process([]) },
        qr/cmd is required/,
        'dies when cmd is an empty arrayref',
    );
    like(
        dies { start_process(undef) },
        qr/cmd is required/,
        'dies when cmd is undef',
    );
};

subtest 'start_process: dies on undef values in cmd' => sub {
    skip_all "fork required" unless $Config{d_fork};
    like(
        dies { start_process([$^X, undef, '-e', '1']) },
        qr/may not contain undefined/,
        'dies when cmd contains an undef element',
    );
};

subtest 'pid_is_running: running process' => sub {
    # $$ is always running and we own it.
    my $rc = pid_is_running($$);
    ok($rc == 1 || $rc == -1, "own pid returns 1 or -1 (running)");
};

subtest 'pid_is_running: nonexistent process' => sub {
    is(pid_is_running(999_999_999), 0, 'implausible pid returns 0');
};

subtest 'pid_is_running: dies without argument' => sub {
    like(
        dies { pid_is_running(0) },
        qr/A pid is required/,
        'dies when pid is 0',
    );
    like(
        dies { pid_is_running(undef) },
        qr/A pid is required/,
        'dies when pid is undef',
    );
};

subtest 'set_procname: sets $0 with prefix' => sub {
    my $old = $0;
    set_procname(set => ['TestWorker']);
    like($0, qr/Test2-Harness2-TestWorker/, 'prefix+name applied to $0');
    $0 = $old;
};

subtest 'set_procname: does not double-prefix' => sub {
    my $old = $0;
    set_procname(set => ['TestWorker']);
    my $first = $0;
    set_procname(set => ['TestWorker']);
    is($0, $first, 'second call does not accumulate another prefix');
    $0 = $old;
};

subtest 'set_procname: append mode' => sub {
    my $old = $0;
    set_procname(set => ['Base']);
    set_procname(append => ['extra']);
    like($0, qr/extra/, 'appended token appears in $0');
    $0 = $old;
};

subtest 'swap_io: redirects handle to a pipe' => sub {
    skip_all "fork required" unless $Config{d_fork};

    pipe(my $r, my $w) or die "pipe: $!";

    # Redirect STDOUT into $w; write through it; read from $r.
    open(my $saved_stdout, '>&', \*STDOUT) or die "dup STDOUT: $!";

    swap_io(\*STDOUT, $w);
    print STDOUT "swap_io_test";
    close $w;

    # Restore STDOUT before reading so any TAP output goes to the real terminal.
    open(STDOUT, '>&', $saved_stdout) or die "restore STDOUT: $!";
    close $saved_stdout;

    my $buf = '';
    sysread($r, $buf, 64);
    close $r;

    is($buf, 'swap_io_test', 'output reached the pipe after swap_io');
};

subtest 'swap_io: croaks when fd cannot be preserved' => sub {
    # swap_io croaks when the reopened handle lands on the wrong fd.
    # We cannot easily trigger that without OS help, so we just verify
    # it croaks on a completely closed handle (no fd at all).
    open(my $dummy, '<', '/dev/null') or skip_all "/dev/null unavailable";
    close $dummy;
    like(
        dies { swap_io($dummy, \*STDOUT) },
        qr/Could not get fd for handle/,
        'croaks when source handle is closed',
    );
};

done_testing;
