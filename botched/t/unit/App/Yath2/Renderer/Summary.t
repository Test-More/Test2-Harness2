use strict;
use warnings;
use Test2::V0;
use File::Temp qw/tempfile/;

BEGIN {
    my $ipcm_lib = '/home/exodist/projects/IPC-Manager/lib';
    if (-d $ipcm_lib) {
        unshift @INC, $ipcm_lib;
    }
}

use App::Yath2::Renderer::Summary;
use Test2::Harness2::Util::JSON qw/decode_json json_true json_false/;

# ===========================================================================
# Basic construction and inheritance
# ===========================================================================

subtest 'construction and inheritance' => sub {
    my $renderer = App::Yath2::Renderer::Summary->new(settings => {});

    isa_ok($renderer, ['App::Yath2::Renderer::Summary']);
    isa_ok($renderer, ['App::Yath2::Renderer']);
    isa_ok($renderer, ['Test2::Harness2::Renderer']);
};

# ===========================================================================
# weight returns -99
# ===========================================================================

subtest 'weight returns -99' => sub {
    my $renderer = App::Yath2::Renderer::Summary->new(settings => {});
    is($renderer->weight, -99, 'weight is -99');
};

# ===========================================================================
# render_event is a no-op
# ===========================================================================

subtest 'render_event is a no-op' => sub {
    my $renderer = App::Yath2::Renderer::Summary->new(settings => {});

    my $ok  = eval { $renderer->render_event({facet_data => {}}); 1 };
    my $err = $@;
    ok($ok, 'render_event does not die') or diag("Error: $err");
};

# ===========================================================================
# exit_hook with mock auditor (hashref) produces summary output
# ===========================================================================

subtest 'exit_hook renders summary to STDOUT' => sub {
    my $renderer = App::Yath2::Renderer::Summary->new(
        color    => 0,
        quiet    => 0,
        settings => {},
    );

    my $mock_auditor = {
        summary => {
            pass         => 1,
            failures     => 0,
            tests_seen   => 5,
            asserts_seen => 42,
        },
        final_data => {},
    };

    my $output = '';
    my $ok;
    my $err;

    {
        local *STDOUT;
        open(STDOUT, '>', \$output) or die "Cannot redirect STDOUT: $!";
        $ok  = eval { $renderer->exit_hook($mock_auditor); 1 };
        $err = $@;
    }

    ok($ok, 'exit_hook does not die') or diag("Error: $err");
    like($output, qr/Yath Result Summary/, 'output contains summary header');
    like($output, qr/File Count: 5/,       'output contains file count');
    like($output, qr/Assertion Count: 42/, 'output contains assertion count');
    like($output, qr/PASSED/,              'output contains PASSED result');
};

# ===========================================================================
# exit_hook with failing summary
# ===========================================================================

subtest 'exit_hook with failing summary' => sub {
    my $renderer = App::Yath2::Renderer::Summary->new(
        color    => 0,
        quiet    => 0,
        settings => {},
    );

    my $mock_auditor = {
        summary => {
            pass         => 0,
            failures     => 3,
            tests_seen   => 10,
            asserts_seen => 100,
        },
        final_data => {
            failed => [
                ['job-1', 't/foo.t', ['subtest A']],
                ['job-2', 't/bar.t', undef],
            ],
        },
    };

    my $output = '';
    {
        local *STDOUT;
        open(STDOUT, '>', \$output) or die "Cannot redirect STDOUT: $!";
        $renderer->exit_hook($mock_auditor);
    }

    like($output, qr/FAILED/,                    'output contains FAILED result');
    like($output, qr/Fail Count: 3/,             'output contains fail count');
    like($output, qr/The following jobs failed/, 'output contains failed jobs table');
    like($output, qr/t\/foo\.t/,                 'output contains failed test file');
};

# ===========================================================================
# exit_hook with time data
# ===========================================================================

subtest 'exit_hook with time data' => sub {
    my $renderer = App::Yath2::Renderer::Summary->new(
        color    => 0,
        quiet    => 0,
        settings => {},
    );

    my $mock_auditor = {
        summary => {
            pass         => 1,
            failures     => 0,
            tests_seen   => 2,
            asserts_seen => 10,
            time_data    => {
                wall    => 5.25,
                cpu     => 4.50,
                user    => 2.00,
                system  => 0.50,
                cuser   => 1.50,
                csystem => 0.50,
            },
            cpu_usage => 86,
        },
        final_data => {},
    };

    my $output = '';
    {
        local *STDOUT;
        open(STDOUT, '>', \$output) or die "Cannot redirect STDOUT: $!";
        $renderer->exit_hook($mock_auditor);
    }

    like($output, qr/Wall Time: 5\.25 seconds/, 'output contains wall time');
    like($output, qr/CPU Time: 4\.50 seconds/,  'output contains CPU time');
    like($output, qr/CPU Usage: 86%/,           'output contains CPU usage');
};

# ===========================================================================
# exit_hook with retried, halted, unseen final_data
# ===========================================================================

subtest 'exit_hook with retried/halted/unseen' => sub {
    my $renderer = App::Yath2::Renderer::Summary->new(
        color    => 0,
        quiet    => 0,
        settings => {},
    );

    my $mock_auditor = {
        summary => {
            pass         => 0,
            failures     => 1,
            tests_seen   => 4,
            asserts_seen => 20,
        },
        final_data => {
            retried => [
                ['job-1', 2, 't/flaky.t', 'YES'],
            ],
            halted => [
                ['job-2', 't/halt.t', 'bail out!'],
            ],
            unseen => [
                ['job-3', 't/never_ran.t'],
            ],
        },
    };

    my $output = '';
    {
        local *STDOUT;
        open(STDOUT, '>', \$output) or die "Cannot redirect STDOUT: $!";
        $renderer->exit_hook($mock_auditor);
    }

    like($output, qr/jobs failed at least once/,            'output contains retried section');
    like($output, qr/t\/flaky\.t/,                          'output contains retried file');
    like($output, qr/jobs requested all testing be halted/, 'output contains halted section');
    like($output, qr/bail out/,                             'output contains halt reason');
    like($output, qr/jobs never ran/,                       'output contains unseen section');
    like($output, qr/t\/never_ran\.t/,                      'output contains unseen file');
};

# ===========================================================================
# JSON file written when file attribute set
# ===========================================================================

subtest 'write_summary_file writes JSON' => sub {
    my ($fh, $tmpfile) = tempfile(SUFFIX => '.json', UNLINK => 1);
    close $fh;

    my $renderer = App::Yath2::Renderer::Summary->new(
        file     => $tmpfile,
        color    => 0,
        quiet    => 0,
        settings => {},
    );

    my $mock_auditor = {
        summary => {
            pass         => 1,
            failures     => 0,
            tests_seen   => 3,
            asserts_seen => 15,
            cpu_usage    => 50,
            time_data    => {
                wall    => 2.0,
                cpu     => 1.5,
                user    => 1.0,
                system  => 0.2,
                cuser   => 0.2,
                csystem => 0.1,
            },
        },
        final_data => {},
    };

    my $output = '';
    {
        local *STDOUT;
        open(STDOUT, '>', \$output) or die "Cannot redirect STDOUT: $!";
        $renderer->exit_hook($mock_auditor);
    }

    like($output, qr/Wrote summary file/, 'output mentions summary file written');

    ok(-f $tmpfile, 'summary JSON file exists');

    open(my $rfh, '<', $tmpfile) or die "Cannot read $tmpfile: $!";
    my $json_text = do { local $/; <$rfh> };
    close $rfh;

    my $data = decode_json($json_text);

    is($data->{pass},           json_true, 'JSON pass is true');
    is($data->{total_failures}, 0,         'JSON total_failures is 0');
    is($data->{total_tests},    3,         'JSON total_tests is 3');
    is($data->{total_asserts},  15,        'JSON total_asserts is 15');
    is($data->{cpu_usage},      50,        'JSON cpu_usage is 50');
    ok($data->{times}, 'JSON times data present');
    is($data->{times}{wall}, 2.0, 'JSON wall time correct');
};

# ===========================================================================
# No JSON file when file attribute not set
# ===========================================================================

subtest 'no JSON file when file not set' => sub {
    my $renderer = App::Yath2::Renderer::Summary->new(
        color    => 0,
        quiet    => 0,
        settings => {},
    );

    my $mock_auditor = {
        summary => {
            pass         => 1,
            failures     => 0,
            tests_seen   => 1,
            asserts_seen => 1,
        },
        final_data => {},
    };

    my $output = '';
    {
        local *STDOUT;
        open(STDOUT, '>', \$output) or die "Cannot redirect STDOUT: $!";
        $renderer->exit_hook($mock_auditor);
    }

    unlike($output, qr/Wrote summary file/, 'no summary file message when file not set');
};

# ===========================================================================
# quiet > 1 suppresses output
# ===========================================================================

subtest 'quiet > 1 suppresses summary output' => sub {
    my $renderer = App::Yath2::Renderer::Summary->new(
        color    => 0,
        quiet    => 2,
        settings => {},
    );

    my $mock_auditor = {
        summary => {
            pass         => 1,
            failures     => 0,
            tests_seen   => 1,
            asserts_seen => 1,
        },
        final_data => {
            failed => [['job-1', 't/x.t', undef]],
        },
    };

    my $output = '';
    {
        local *STDOUT;
        open(STDOUT, '>', \$output) or die "Cannot redirect STDOUT: $!";
        $renderer->exit_hook($mock_auditor);
    }

    is($output, '', 'no output when quiet > 1');
};

done_testing;
