use Test2::V0;

use File::Temp qw/tempdir/;
use Test2::Harness2;
use Test2::Harness2::Collector::Logger::JSONL ();
use Test2::Harness2::Util::JSON qw/decode_json_zst_file/;

subtest blessed_and_injected => sub {
    my $wd = tempdir(CLEANUP => 1);

    my $h = Test2::Harness2->new(
        workdir     => $wd,
        name        => 'h',
        ipcm_info   => {},
        bus_id      => 'test',
        parent_pids => [$$],
    );

    # Blessed logger instance with a caller-supplied output_file.
    my $inst = Test2::Harness2::Collector::Logger::JSONL->new(
        ipcm_info   => {},
        output_file => "$wd/logs/services/h.jsonl",
    );
    push @{$h->{Test2::Harness2->LOGGERS}} => $inst;

    $h->_seed_artifacts_from_loggers;

    # Inject a global collector_artifacts (run_id => undef) to simulate
    # a resource-service collector reporting its own log files.
    $h->_handle_global_collector_artifacts({
        run_id  => undef,
        loggers => {
            'Test2::Harness2::Collector::Logger::JSON' => [
                {json_file => "$wd/logs/services/resource-disk.json"},
            ],
        },
    });

    my $data = decode_json_zst_file("$wd/logs/artifacts.json.zst", -f "$wd/logs/zstd-dict.bin" ? (dict_path => "$wd/logs/zstd-dict.bin") : ());
    is(
        $data,
        {
            'services/h.jsonl'            => 'Test2::Harness2::Collector::Logger::JSONL',
            'services/resource-disk.json' => 'Test2::Harness2::Collector::Logger::JSON',
        },
        'harness artifacts.json contains both seeded and injected entries',
    );
};

subtest arrayref_spec_instantiated => sub {
    my $wd = tempdir(CLEANUP => 1);

    my $h = Test2::Harness2->new(
        workdir     => $wd,
        name        => 'h',
        ipcm_info   => {},
        bus_id      => 'test',
        parent_pids => [$$],
    );

    # Arrayref spec -- identity (logdir, service_name='h') is supplied
    # by _logger_instance_for_metadata; JSONL resolves its output path
    # via the role's output_file_basename rules.
    push @{$h->{Test2::Harness2->LOGGERS}} => ['Test2::Harness2::Collector::Logger::JSONL'];

    $h->_seed_artifacts_from_loggers;

    my $data = decode_json_zst_file("$wd/logs/artifacts.json.zst", -f "$wd/logs/zstd-dict.bin" ? (dict_path => "$wd/logs/zstd-dict.bin") : ());
    is(
        $data,
        {'services/h.jsonl.zst' => 'Test2::Harness2::Collector::Logger::JSONL'},
        'arrayref logger spec contributes to artifacts.json',
    );
};

done_testing;
