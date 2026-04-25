use Test2::V0;

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use App::Yath2::LogArchive;
use Test2::Harness2::Util::JSON qw/write_json_zst_file_atomic/;

my $dir = tempdir(CLEANUP => 1);
make_path("$dir/services");
make_path("$dir/runs/R1/services");
make_path("$dir/runs/R1/J1");
make_path("$dir/runs/R2/services");

# Stub artifact files. Names match the .zst suffix convention used
# by the live loggers so the LogArchive lookups (which key by
# artifacts.json.zst) find them. Contents stay empty/zero -- they
# are only used to confirm existence and rogue-file detection.
open my $fh, '>', "$dir/services/harness.jsonl.zst" or die $!; close $fh;
open $fh,    '>', "$dir/services/harness.json.zst"  or die $!; close $fh;
open $fh,    '>', "$dir/runs/R1/services/run.jsonl.zst" or die $!; close $fh;
open $fh,    '>', "$dir/runs/R1/J1/0.jsonl.zst"     or die $!; close $fh;
open $fh,    '>', "$dir/runs/R1/J1/rogue.txt"       or die $!; print $fh "rogue\n"; close $fh;

write_json_zst_file_atomic(
    "$dir/artifacts.json.zst",
    {
        'services/harness.jsonl.zst' => 'Test2::Harness2::Collector::Logger::JSONL',
        'services/harness.json.zst'  => 'Test2::Harness2::Collector::Logger::JSON',
    },
);
write_json_zst_file_atomic(
    "$dir/runs/R1/artifacts.json.zst",
    {
        'runs/R1/services/run.jsonl.zst' => 'Test2::Harness2::Collector::Logger::JSONL',
        'runs/R1/J1/0.jsonl.zst'         => 'Test2::Harness2::Collector::Logger::JSONL',
    },
);
# R2 intentionally has no artifacts.json.zst to test include_empty.

my $la = App::Yath2::LogArchive->new(path => $dir);
isa_ok($la, 'App::Yath2::LogArchive::Directory');

is(
    $la->artifacts,
    {
        'services/harness.jsonl.zst' => 'Test2::Harness2::Collector::Logger::JSONL',
        'services/harness.json.zst'  => 'Test2::Harness2::Collector::Logger::JSON',
    },
    'global artifacts',
);

is(
    $la->artifacts('R1'),
    {
        'runs/R1/services/run.jsonl.zst' => 'Test2::Harness2::Collector::Logger::JSONL',
        'runs/R1/J1/0.jsonl.zst'         => 'Test2::Harness2::Collector::Logger::JSONL',
    },
    'run-scoped artifacts',
);

is([sort $la->runs],                     ['R1'],         'runs() defaults to runs with manifests');
is([sort $la->runs(include_empty => 1)], ['R1', 'R2'],   'runs(include_empty => 1)');

is([sort $la->services],       ['harness'], 'global services');
is([sort $la->services('R1')], ['run'],     'run-scoped services');

is([sort $la->rogue_files('R1')], ['runs/R1/J1/rogue.txt'], 'rogue files under R1');
is([sort $la->rogue_files],       [],                        'no global rogue files');

done_testing;
