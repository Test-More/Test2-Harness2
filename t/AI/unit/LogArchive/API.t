use Test2::V0;

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use App::Yath2::LogArchive;
use Test2::Harness2::Util::JSON qw/write_json_file_atomic/;

my $dir = tempdir(CLEANUP => 1);
make_path("$dir/services");
make_path("$dir/runs/R1/services");
make_path("$dir/runs/R1/J1");
make_path("$dir/runs/R2/services");

open my $fh, '>', "$dir/services/harness.jsonl"     or die $!; print $fh "\n";    close $fh;
open $fh,    '>', "$dir/services/harness.json"      or die $!; print $fh "{}";    close $fh;
open $fh,    '>', "$dir/runs/R1/services/run.jsonl" or die $!; print $fh "\n";    close $fh;
open $fh,    '>', "$dir/runs/R1/J1/0.jsonl"         or die $!; print $fh "\n";    close $fh;
open $fh,    '>', "$dir/runs/R1/J1/rogue.txt"       or die $!; print $fh "rogue\n"; close $fh;

write_json_file_atomic(
    "$dir/artifacts.json",
    {
        'services/harness.jsonl' => 'Test2::Harness2::Collector::Logger::JSONL',
        'services/harness.json'  => 'Test2::Harness2::Collector::Logger::JSON',
    },
);
write_json_file_atomic(
    "$dir/runs/R1/artifacts.json",
    {
        'runs/R1/services/run.jsonl' => 'Test2::Harness2::Collector::Logger::JSONL',
        'runs/R1/J1/0.jsonl'         => 'Test2::Harness2::Collector::Logger::JSONL',
    },
);
# R2 intentionally has no artifacts.json to test include_empty.

my $la = App::Yath2::LogArchive->new(path => $dir);
isa_ok($la, 'App::Yath2::LogArchive::Directory');

is(
    $la->artifacts,
    {
        'services/harness.jsonl' => 'Test2::Harness2::Collector::Logger::JSONL',
        'services/harness.json'  => 'Test2::Harness2::Collector::Logger::JSON',
    },
    'global artifacts',
);

is(
    $la->artifacts('R1'),
    {
        'runs/R1/services/run.jsonl' => 'Test2::Harness2::Collector::Logger::JSONL',
        'runs/R1/J1/0.jsonl'         => 'Test2::Harness2::Collector::Logger::JSONL',
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
