use Test2::V0;

use Test2::Harness2::Util::IPC qw{
    pid_is_running
    set_procname
    start_process
    parse_exit
    swap_io
    list_direct_children
    atomic_pipe_compression_args
    apply_atomic_pipe_compression
};

subtest pid_is_running => sub {
    is(pid_is_running($$), 1, 'self running');
    # init / pid 1 is running but we (likely) don't own it
    my $rc = pid_is_running(1);
    ok($rc != 0, 'pid 1 not gone');
    like(dies { pid_is_running(undef) }, qr/required/);
};

subtest set_procname => sub {
    my $orig = $0;
    set_procname(set => ['foo', 'bar']);
    like($0, qr/^Test2-Harness2-foo-bar$/);
    set_procname(set => ['baz'], prefix => 'X-Pref');
    like($0, qr/^X-Pref-baz$/);
    $0 = $orig;
};

subtest start_process_basic => sub {
    my $pid = start_process(['perl', '-e', 'exit 7']);
    ok($pid, 'got pid');
    waitpid($pid, 0);
    is($? >> 8, 7, 'exit code 7');
};

subtest start_process_validation => sub {
    like(dies { start_process(undef) },     qr/cmd is required/);
    like(dies { start_process([]) },        qr/cmd is required/);
    like(dies { start_process([undef]) },   qr/undefined values/);
};

subtest parse_exit => sub {
    is(parse_exit(0),   {sig => 0,  err => 0, dmp => 0,   all => 0});
    is(parse_exit(256), {sig => 0,  err => 1, dmp => 0,   all => 256});
    is(parse_exit(15),  {sig => 15, err => 0, dmp => 0,   all => 15});
    is(parse_exit(143), {sig => 15, err => 0, dmp => 128, all => 143});
    like(dies { parse_exit(undef) }, qr/exit value is required/);
};

subtest swap_io => sub {
    my ($r, $w);
    pipe($r, $w) or die "pipe: $!";

    my $pid = fork // die "fork: $!";
    if (!$pid) {
        close $r;
        swap_io(\*STDOUT, $w);
        print "hi\n";
        close STDOUT;
        exit 0;
    }
    close $w;
    waitpid($pid, 0);
    my $got = do { local $/; <$r> };
    is($got, "hi\n");
};

subtest list_direct_children => sub {
    my $pid = start_process(['perl', '-e', 'sleep 30']);
    my @kids = list_direct_children($$);
    ok((grep { $_ == $pid } @kids), 'child enumerated');
    kill 'TERM', $pid;
    waitpid($pid, 0);
};

subtest atomic_pipe_args => sub {
    my %a = atomic_pipe_compression_args();
    is($a{compression},     'zstd');
    is($a{keep_compressed}, 1);
};

subtest apply_atomic_pipe_compression_undef => sub {
    ok(lives { apply_atomic_pipe_compression(undef) }, 'undef is a no-op');
};

done_testing;
