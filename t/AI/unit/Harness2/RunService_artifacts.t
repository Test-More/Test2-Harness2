use Test2::V0;

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use Test2::Harness2::Run;
use Test2::Harness2::RunService;
use Test2::Harness2::Util::JSON qw/decode_json_zst_file/;

my $wd = tempdir(CLEANUP => 1);
make_path("$wd/logs/runs/R1/services");

my $run = Test2::Harness2::Run->new(run_id => 'R1');

# Minimal ipcm_info stub: RunService only stores it, nothing in this
# test triggers IPC send paths.
my $svc = Test2::Harness2::RunService->new(
    workdir     => $wd,
    run         => $run,
    name        => 'run:R1',
    ipcm_info   => {},
    bus_id      => 'test',
    parent_pids => [$$],
);

# Simulate two collector_artifacts messages for the same run.
$svc->_handle_collector_artifacts({
    run_id  => 'R1',
    job_id  => 'J1',
    job_try => 0,
    loggers => {
        'Test2::Harness2::Collector::Logger::JSONL' => [
            {jsonl_file => "$wd/logs/runs/R1/J1/0.jsonl"},
        ],
        'Test2::Harness2::Collector::Logger::JSON' => [
            {json_file => "$wd/logs/runs/R1/J1/0.json"},
        ],
    },
});

$svc->_handle_collector_artifacts({
    run_id  => 'R1',
    job_id  => 'J2',
    job_try => 0,
    loggers => {
        'Test2::Harness2::Collector::Logger::JSONL' => [
            {jsonl_file => "$wd/logs/runs/R1/J2/0.jsonl"},
        ],
    },
});

my $data = decode_json_zst_file("$wd/logs/runs/R1/artifacts.json.zst", -f "$wd/logs/zstd-dict.bin" ? (dict_path => "$wd/logs/zstd-dict.bin") : ());
is(
    $data,
    {
        'runs/R1/J1/0.jsonl' => 'Test2::Harness2::Collector::Logger::JSONL',
        'runs/R1/J1/0.json'  => 'Test2::Harness2::Collector::Logger::JSON',
        'runs/R1/J2/0.jsonl' => 'Test2::Harness2::Collector::Logger::JSONL',
    },
    'per-run artifacts.json contains all three entries keyed by relpath',
);

done_testing;
