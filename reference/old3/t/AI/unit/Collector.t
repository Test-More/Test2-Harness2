use Test2::V0;
use File::Temp qw/tempdir/;
use POSIX qw/:sys_wait_h/;
use Config;
use Time::HiRes qw/sleep/;
use Test2::Harness2::Util::JSON qw/decode_json encode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_reader/;

use Test2::Harness2::Collector;

# Force-load the Win32-only methods so cross-platform tests below
# can introspect them on every platform.
use Test2::Harness2::Collector::Win32;

# The real IPC bus is not running under these unit tests, so stub
# IPC::Manager::connect out so collectors can spawn without an
# actual bus running.
BEGIN {
    require IPC::Manager;
    no warnings 'once', 'redefine';
    *IPC::Manager::connect = sub {
        return bless {}, 'T2H2_TestNoopClient';
    };
    *T2H2_TestNoopClient::send_message          = sub { return };
    *T2H2_TestNoopClient::try_send_message      = sub { return 1 };
    *T2H2_TestNoopClient::peer_active           = sub { 1 };
    *T2H2_TestNoopClient::disconnect            = sub { return };
    *T2H2_TestNoopClient::pending_sends         = sub { 0 };
    *T2H2_TestNoopClient::have_pending_sends    = sub { 0 };
    *T2H2_TestNoopClient::drain_pending         = sub { 0 };
    *T2H2_TestNoopClient::have_writable_handles = sub { 0 };
    *T2H2_TestNoopClient::writable_handles      = sub { () };
    *T2H2_TestNoopClient::set_send_blocking     = sub { return };
}

my $IS_WIN32 = $^O eq 'MSWin32';
my $CAN_FORK = $Config{d_fork};

# Read the zstd-compressed jsonl trio that every collector now writes.
sub read_zstd_jsonl {
    my ($path) = @_;
    return () unless -f $path;
    my $r = open_zstd_reader($path);
    my @rows;
    while (defined(my $line = $r->readline)) {
        chomp $line;
        next unless length $line;
        push @rows, decode_json($line);
    }
    $r->close;
    return @rows;
}

subtest 'init - required attributes' => sub {
    like(
        dies { Test2::Harness2::Collector->new(ipcm_info => {}) },
        qr/'ipc_harness' is a required attribute/,
        'ipc_harness required',
    );

    like(
        dies {
            Test2::Harness2::Collector->new(
                ipcm_info   => {},
                ipc_harness => 'h',
            );
        },
        qr/'type' is a required attribute/,
        'type required',
    );

    like(
        dies {
            Test2::Harness2::Collector->new(
                ipcm_info   => {},
                ipc_harness => 'h',
                type        => 'Bogus',
                id          => 0,
            );
        },
        qr/Invalid type/,
        'type validated',
    );

    like(
        dies {
            Test2::Harness2::Collector->new(
                ipcm_info   => {},
                ipc_harness => 'h',
                type        => 'Service',
            );
        },
        qr/'id' is a required attribute/,
        'id required',
    );

    like(
        dies {
            Test2::Harness2::Collector->new(
                ipcm_info   => {},
                ipc_harness => 'h',
                type        => 'Job',
                id          => 0,
            );
        },
        qr/'run_id' is required for type=Job/,
        'run_id required for Job',
    );
};

subtest 'base_dir - layout per type' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);

    my $svc = Test2::Harness2::Collector->new(
        ipcm_info   => {},
        ipc_harness => 'h',
        type        => 'Service',
        id          => 'harness',
        logdir      => $tmpdir,
        launch      => ['perl', '-e', 1],
    );
    is($svc->base_dir, "$tmpdir/services/harness", 'global service base');

    my $run = Test2::Harness2::Collector->new(
        ipcm_info   => {},
        ipc_harness => 'h',
        type        => 'Run',
        id          => 0,
        run_id      => 0,
        logdir      => $tmpdir,
        launch      => ['perl', '-e', 1],
    );
    is($run->base_dir, "$tmpdir/runs/0", 'run base');

    my $job = Test2::Harness2::Collector->new(
        ipcm_info   => {},
        ipc_harness => 'h',
        type        => 'Job',
        id          => 1,
        run_id      => 0,
        job_try     => 0,
        logdir      => $tmpdir,
        launch      => ['perl', '-e', 1],
    );
    is($job->base_dir, "$tmpdir/runs/0/jobs/1/0", 'job base');

    my $rsvc = Test2::Harness2::Collector->new(
        ipcm_info   => {},
        ipc_harness => 'h',
        type        => 'Service',
        id          => 'res',
        run_id      => 0,
        logdir      => $tmpdir,
        launch      => ['perl', '-e', 1],
    );
    is($rsvc->base_dir, "$tmpdir/runs/0/services/res", 'run-scoped service base');
};

subtest 'launch - writes spec + events + report files' => sub {
    skip_all "fork required" unless $CAN_FORK;

    my $tmpdir = tempdir(CLEANUP => 1);

    my $h = Test2::Harness2::Collector->spawn(
        ipcm_info   => {},
        ipc_harness => 'h',
        type        => 'Job',
        id          => 0,
        run_id      => 0,
        job_try     => 0,
        logdir      => $tmpdir,
        spec        => {file => 'fake.t'},
        launch      => ['perl', '-e', 'print "hello\n"'],
    );

    ok($h,      'collector spawned');
    ok($h->pid, 'collector pid set');

    my $exit = $h->wait();
    is($exit, 0, 'child exited 0');

    my $base = "$tmpdir/runs/0/jobs/0/0";
    ok(-f "$base/spec.jsonl.zst",   'spec.jsonl.zst exists');
    ok(-f "$base/events.jsonl.zst", 'events.jsonl.zst exists');
    ok(-f "$base/report.jsonl.zst", 'report.jsonl.zst exists');

    my @spec = read_zstd_jsonl("$base/spec.jsonl.zst");
    is(scalar @spec, 1, 'one spec row');
    is($spec[0]{type}, 'Job',   'spec.type=Job');
    is($spec[0]{id},   0,       'spec.id=0');
    is($spec[0]{run_id}, 0,     'spec.run_id=0');
    ok(defined $spec[0]{collector_pid}, 'spec.collector_pid present');
    is($spec[0]{file}, 'fake.t', 'spec carries caller-supplied fields');

    my @events = read_zstd_jsonl("$base/events.jsonl.zst");
    ok(scalar @events, 'at least one event written');

    my @report = read_zstd_jsonl("$base/report.jsonl.zst");
    is(scalar @report, 1, 'one report row');
    ok(defined $report[0]{ended_at},   'report.ended_at');
    ok(defined $report[0]{collector_pid}, 'report.collector_pid');
    is($report[0]{exit}, 0, 'report.exit=0');
};

subtest 'service collector - writes its trio' => sub {
    skip_all "fork required" unless $CAN_FORK;

    my $tmpdir = tempdir(CLEANUP => 1);

    my $h = Test2::Harness2::Collector->spawn(
        ipcm_info   => {},
        ipc_harness => 'h',
        type        => 'Service',
        id          => 'svc',
        logdir      => $tmpdir,
        launch      => ['perl', '-e', 'print "svc up\n"'],
    );

    my $exit = $h->wait();
    is($exit, 0, 'service child exited 0');

    my $base = "$tmpdir/services/svc";
    ok(-f "$base/spec.jsonl.zst",   'spec exists');
    ok(-f "$base/events.jsonl.zst", 'events exists');
    ok(-f "$base/report.jsonl.zst", 'report exists');

    my @spec = read_zstd_jsonl("$base/spec.jsonl.zst");
    is($spec[0]{type}, 'Service', 'spec.type=Service');
    is($spec[0]{id},   'svc',     'spec.id=svc');
};

subtest 'restart - appends another spec row' => sub {
    skip_all "fork required" unless $CAN_FORK;

    my $tmpdir = tempdir(CLEANUP => 1);

    for my $i (1, 2) {
        my $h = Test2::Harness2::Collector->spawn(
            ipcm_info   => {},
            ipc_harness => 'h',
            type        => 'Service',
            id          => 'restart-svc',
            logdir      => $tmpdir,
            spec        => {iteration => $i},
            launch      => ['perl', '-e', 1],
        );
        $h->wait;
    }

    my $base = "$tmpdir/services/restart-svc";
    my @spec = read_zstd_jsonl("$base/spec.jsonl.zst");
    is(scalar @spec, 2, 'two spec rows after restart');
    is($spec[0]{iteration}, 1, 'first iteration recorded');
    is($spec[1]{iteration}, 2, 'second iteration recorded');

    my @report = read_zstd_jsonl("$base/report.jsonl.zst");
    is(scalar @report, 2, 'two report rows after restart');
};

done_testing;
