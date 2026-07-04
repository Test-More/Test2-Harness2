use v5.38;

use Test2::V0;

use POSIX ();

use Test2::Harness2::Util::FdPass qw{
    fdpass_available
    command_listen
    send_fds
};
use Test2::Harness2::Interactive qw{
    interactive_socket
    connect_stdin
};

# These tests prove the interactive STDIN choreography: the command opens a
# listen socket and passes its REAL STDIN descriptor over SCM_RIGHTS; the test
# process dials in, receives the one fd, and dup2s it onto fd 0 -- so reading
# STDIN in the test reads the command's terminal/pipe directly. Both the preload
# (goto::file filter) and no-preload (-MTest2::Harness2::Interactive import) paths
# route through Test2::Harness2::Interactive::connect_stdin, so exercising it
# covers both.

subtest interactive_socket_reads_env => sub {
    local $ENV{YATH_INTERACTIVE};
    delete $ENV{YATH_INTERACTIVE};
    is(interactive_socket(), undef, "no socket path when env var unset");

    local $ENV{YATH_INTERACTIVE} = '';
    is(interactive_socket(), undef, "empty env var counts as unset");

    local $ENV{YATH_INTERACTIVE} = '/tmp/some.sock';
    is(interactive_socket(), '/tmp/some.sock', "returns the env var path when set");
};

subtest connect_stdin_no_op_without_env => sub {
    local $ENV{YATH_INTERACTIVE};
    delete $ENV{YATH_INTERACTIVE};
    is(connect_stdin(), 0, "connect_stdin is a no-op (false) with no socket path");
};

unless (fdpass_available()) {
    # Without IO::FDPass the descriptor cannot be passed; the env/no-op guards
    # above are the absent-path coverage. connect_stdin with a path would die via
    # require_fdpass, which is covered in Util_FdPass.t.
    done_testing;
    exit 0;
}

# Drive the full choreography: a "command" process holding a scripted STDIN passes
# it to a forked "test" process, which dup2s it onto fd 0 via connect_stdin and
# reads the scripted bytes. The test's STDOUT is captured back so we can assert it
# received the command's STDIN.
sub _run_interactive_roundtrip {
    my ($stdin_text) = @_;

    # The command's "real STDIN": a pipe pre-loaded with the scripted bytes.
    pipe(my $stdin_r, my $stdin_w) or die "pipe failed: $!";
    $stdin_w->autoflush(1);
    print $stdin_w $stdin_text;
    close($stdin_w);

    # Capture the test child's STDOUT.
    pipe(my $out_r, my $out_w) or die "pipe failed: $!";

    my ($listen, $path) = command_listen();

    my $pid = fork // die "fork failed: $!";
    if (!$pid) {
        # The test process: give up the listener + capture-read end, make $out_w
        # our STDOUT, point STDIN at the scripted pipe (as a clean exec'd test
        # would inherit nothing useful), then dial in and dup2 the passed fd.
        close($listen);
        close($out_r);
        open(\*STDOUT, '>&=', fileno($out_w)) or die "reopen stdout: $!";
        STDOUT->autoflush(1);

        my $ok = eval {
            local $ENV{YATH_INTERACTIVE} = $path;
            connect_stdin();
            my $got = <STDIN>;
            print STDOUT "RECEIVED:$got";
            1;
        };
        POSIX::_exit($ok ? 0 : 1);
    }

    close($out_w);

    # The command: accept the dial-back and pass its real STDIN once (per-test).
    my $conn = $listen->accept or die "accept failed: $!";
    send_fds($conn, [fileno($stdin_r)]);
    close($conn);

    my $captured = <$out_r>;
    waitpid($pid, 0);
    my $exit = $? >> 8;
    unlink($path);

    return ($captured, $exit);
}

subtest connect_stdin_installs_passed_fd_on_fd0 => sub {
    my ($captured, $exit) = _run_interactive_roundtrip("scripted-stdin-line\n");

    is($exit, 0, "the test process completed cleanly");
    is($captured, "RECEIVED:scripted-stdin-line\n",
        "the test read the command's STDIN after connect_stdin dup2'd it onto fd 0");
};

# (G6, ticket TODO-140) connect_stdin scrubs $ENV{YATH_INTERACTIVE} from the live env
# immediately after installing STDIN (before any test-body code), so no user code
# runs with the socket path visible -- every interactive re-dial path is gated on
# that variable. Drive a child through the handshake for BOTH call forms and have
# it report whether the var survived.
sub _run_env_scrub_probe {
    my ($form) = @_;

    pipe(my $stdin_r, my $stdin_w) or die "pipe failed: $!";
    $stdin_w->autoflush(1);
    print $stdin_w "ignored\n";
    close($stdin_w);

    pipe(my $out_r, my $out_w) or die "pipe failed: $!";

    my ($listen, $path) = command_listen();

    my $pid = fork // die "fork failed: $!";
    if (!$pid) {
        close($listen);
        close($out_r);
        open(\*STDOUT, '>&=', fileno($out_w)) or die "reopen stdout: $!";
        STDOUT->autoflush(1);

        my $ok = eval {
            local $ENV{YATH_INTERACTIVE} = $path;
            $form eq 'explicit' ? connect_stdin($path) : connect_stdin();
            print STDOUT "ENV:" . (defined $ENV{YATH_INTERACTIVE} ? "SET" : "UNSET") . "\n";
            1;
        };
        POSIX::_exit($ok ? 0 : 1);
    }

    close($out_w);

    my $conn = $listen->accept or die "accept failed: $!";
    send_fds($conn, [fileno($stdin_r)]);
    close($conn);

    my $line = <$out_r>;
    waitpid($pid, 0);
    my $exit = $? >> 8;
    unlink($path);
    chomp($line) if defined $line;

    return ($line // 'NO-OUTPUT', $exit);
}

subtest connect_stdin_scrubs_env_after_handshake => sub {
    for my $form (qw/env explicit/) {
        my ($state, $exit) = _run_env_scrub_probe($form);
        is($exit, 0, "$form-path child completed the handshake cleanly");
        is($state, "ENV:UNSET",
            "$form-path: YATH_INTERACTIVE scrubbed from live env after connect_stdin");
    }
};

subtest per_test_accept_passes_to_each_test_in_turn => sub {
    # -j1 means N sequential tests; the command keeps its listener open and passes
    # the STDIN fd once per test. Model that: one listener, two sequential dial-ins,
    # each getting the same real STDIN and reading its own line. The bytes for each
    # test are written just before that test's pass (as a user types between
    # prompts), and each test sysread's exactly its line so buffered stdio cannot
    # over-read into the next test's input.
    pipe(my $stdin_r, my $stdin_w) or die "pipe failed: $!";
    $stdin_w->autoflush(1);

    my ($listen, $path) = command_listen();

    my @captured;
    for my $n (1 .. 2) {
        my $expect = "line-$n\n";
        print $stdin_w $expect;

        pipe(my $out_r, my $out_w) or die "pipe failed: $!";

        my $pid = fork // die "fork failed: $!";
        if (!$pid) {
            close($listen);
            close($out_r);
            open(\*STDOUT, '>&=', fileno($out_w)) or die "reopen stdout: $!";
            STDOUT->autoflush(1);
            my $ok = eval {
                local $ENV{YATH_INTERACTIVE} = $path;
                connect_stdin();
                my $got = '';
                sysread(\*STDIN, $got, length($expect));
                print STDOUT $got;
                1;
            };
            POSIX::_exit($ok ? 0 : 1);
        }

        close($out_w);
        my $conn = $listen->accept or die "accept failed: $!";
        send_fds($conn, [fileno($stdin_r)]);
        close($conn);

        my $line = <$out_r>;
        waitpid($pid, 0);
        is($? >> 8, 0, "sequential test #$n completed cleanly");
        push @captured => $line;
    }

    close($stdin_w);
    unlink($path);

    is(\@captured, ["line-1\n", "line-2\n"],
        "each sequential test received its line of the command's STDIN (one pass per test)");
};

done_testing;
