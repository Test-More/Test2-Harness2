use Test2::V0;

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;

use Test2::Harness2::Util::JSON qw/write_json_file_atomic encode_json/;

use App::Yath2::Command::failed;

# Build a synthetic log directory carrying a single run with two
# completed jobs (one pass, one fail). The streamer reads this back
# via App::Yath2::LogArchive::Directory and the command groups by
# rel_file. Subtest collection walks the per-job JSONLs directly via
# the archive so any parent/assert facets there get picked up.

sub build_logs {
    my (%opts) = @_;
    my $tmp    = tempdir(CLEANUP => 1);
    my $logdir = "$tmp/logs";
    make_path("$logdir/runs/R/tests");

    my $artifacts = {
        "runs/R.json"           => 'Test2::Harness2::Collector::Logger::JSON',
        "runs/R/tests/J1.jsonl" => 'Test2::Harness2::Collector::Logger::JSONL',
        "runs/R/tests/J2.jsonl" => 'Test2::Harness2::Collector::Logger::JSONL',
    };
    write_json_file_atomic("$logdir/artifacts.json",        $artifacts);
    write_json_file_atomic("$logdir/runs/R/artifacts.json", $artifacts);

    write_json_file_atomic(
        "$logdir/runs/R.json",
        {
            run_id     => 'R',
            created_at => 1,
            pending    => [],
            running    => [],
            done       => ['J1', 'J2'],
            results    => {
                J1 => {
                    job_id       => 'J1',
                    job_try      => 0,
                    queued_at    => 1,
                    started_at   => 2,
                    completed_at => 3,
                    pass         => $opts{j1_pass} // 1,
                    exit         => $opts{j1_pass} ? 0 : 256,
                    rel_file     => 'pass.t',
                    abs_file     => '/abs/pass.t',
                    file         => '/abs/pass.t',
                },
                J2 => {
                    job_id       => 'J2',
                    job_try      => 0,
                    queued_at    => 1,
                    started_at   => 2,
                    completed_at => 4,
                    pass         => 0,
                    exit         => 256,
                    rel_file     => 'fail.t',
                    abs_file     => '/abs/fail.t',
                    file         => '/abs/fail.t',
                },
            },
        },
    );

    # Empty per-job event logs -- the command must still report the
    # failure (tagged via the state snapshot) and produce an empty
    # subtest list rather than crash.
    open my $j1, '>', "$logdir/runs/R/tests/J1.jsonl" or die $!;
    close $j1;

    # J2 (fail.t) has a failing subtest event so the subtest column
    # gets populated for the fail row.
    open my $j2, '>', "$logdir/runs/R/tests/J2.jsonl" or die $!;
    print $j2 encode_json({
        event_id   => 'E1',
        facet_data => {
            assert => {pass     => 0, details => 'inner fail'},
            parent => {children => []},
            trace  => {nested   => 0},
        },
        }),
        "\n";
    close $j2;

    return $logdir;
}

sub make_cmd {
    my (%opts) = @_;
    my $brief  = $opts{brief} // 0;
    my $log    = $opts{log};
    my $fs     = mock {} => (add => [brief  => sub { $brief }]);
    my $s      = mock {} => (add => [failed => sub { $fs }]);
    return App::Yath2::Command::failed->new(
        settings => $s,
        args     => [$log],
        plugins  => [],
    );
}

# ----------------------------------------------------------------------
subtest 'brief mode prints just the failed file paths' => sub {
    my $log = build_logs();
    my $cmd = make_cmd(log => $log, brief => 1);

    my $out = '';
    {
        open my $fh, '>', \$out or die $!;
        local *STDOUT = $fh;
        is($cmd->run, 0, 'run() returned 0');
    }

    is($out, "fail.t\n", 'brief output is just the failing rel_file');
};

# ----------------------------------------------------------------------
subtest 'table mode lists each failing job' => sub {
    my $log = build_logs();
    my $cmd = make_cmd(log => $log, brief => 0);

    my $out = '';
    {
        open my $fh, '>', \$out or die $!;
        local *STDOUT = $fh;
        is($cmd->run, 0, 'run() returned 0');
    }

    like($out, qr/fail\.t/, 'fail.t appears in the table');
    unlike($out, qr/^\s*\Q| pass.t\E/m, 'pass.t is excluded from the table');
    like($out, qr/inner fail/,           'subtest name from per-job JSONL is included');
    like($out, qr/Succeeded Eventually/, 'header includes Succeeded Eventually');
};

# ----------------------------------------------------------------------
subtest 'no failures -> friendly message' => sub {
    my $log = build_logs(j1_pass => 1);
    open my $fh, '>>', "$log/runs/R/tests/J2.jsonl" or die $!;    # noop
    close $fh;

    # Force every job to pass by rewriting state.
    write_json_file_atomic(
        "$log/runs/R.json",
        {
            run_id     => 'R',
            created_at => 1,
            pending    => [],
            running    => [],
            done       => ['J1'],
            results    => {
                J1 => {
                    job_id       => 'J1',
                    job_try      => 0,
                    queued_at    => 1,
                    started_at   => 2,
                    completed_at => 3,
                    pass         => 1,
                    exit         => 0,
                    rel_file     => 'pass.t',
                    abs_file     => '/abs/pass.t',
                    file         => '/abs/pass.t',
                },
            },
        },
    );

    my $cmd = make_cmd(log => $log);

    my $out = '';
    {
        open my $sfh, '>', \$out or die $!;
        local *STDOUT = $sfh;
        is($cmd->run, 0, 'run() returned 0');
    }

    like($out, qr/No jobs failed/, 'reports "No jobs failed!" when nothing failed');
};

# ----------------------------------------------------------------------
subtest 'unknown run id is rejected' => sub {
    my $log = build_logs();
    my $cmd = App::Yath2::Command::failed->new(
        settings => mock(
            {} => (
                add => [
                    failed => sub {
                        mock {} => (add => [brief => sub { 0 }]);
                    }
                ]
            )
        ),
        args    => [$log, 'NOPE'],
        plugins => [],
    );

    like(dies { $cmd->run }, qr/unknown run 'NOPE'/, 'unknown run id dies');
};

# ----------------------------------------------------------------------
subtest 'missing log path dies cleanly' => sub {
    my $cmd = App::Yath2::Command::failed->new(
        settings => mock(
            {} => (
                add => [
                    failed => sub {
                        mock {} => (add => [brief => sub { 0 }]);
                    }
                ]
            )
        ),
        args    => ['/no/such/path/should/exist'],
        plugins => [],
    );

    like(dies { $cmd->run }, qr/does not exist/, 'missing log dies with helpful error');
};

done_testing;
