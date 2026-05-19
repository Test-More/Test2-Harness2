use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;

use Test2::Harness2::Util::JSON qw/encode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
use App::Yath2::Log;

# Build a synthetic log directory and archive it. Mirrors the
# Directory listing test (so the same fixture exercises both backends).
my $src = tempdir(CLEANUP => 1);
make_path("$src/services/harness");
make_path("$src/services/preload-perl");
make_path("$src/runs/0/services/run");
make_path("$src/runs/0/jobs/0/0");
make_path("$src/runs/0/jobs/0/1");
make_path("$src/runs/0/jobs/1/0");
make_path("$src/runs/2/jobs/0/0");

# A single events.jsonl.zst per dir is enough for the TarZIdx writer
# to see something to capture (empty dirs are also tracked, but giving
# every collector a token event removes any ambiguity).
for my $base (
    "services/harness",
    "services/preload-perl",
    "runs/0",
    "runs/0/services/run",
    "runs/0/jobs/0/0",
    "runs/0/jobs/0/1",
    "runs/0/jobs/1/0",
    "runs/2",
    "runs/2/jobs/0/0",
) {
    my $w = open_zstd_writer("$src/$base/events.jsonl.zst");
    $w->say(encode_json({ping => 1}));
    $w->close;
}

# Archive to a tar.zidx file.
my $arc_dir = tempdir(CLEANUP => 1);
my $arc_path = "$arc_dir/run.yath";
App::Yath2::Log->new(dir => $src)->archive($arc_path);

my $log = App::Yath2::Log->new(file => $arc_path);
isa_ok($log, ['App::Yath2::Log::TarZIdx']);

is([$log->services], ['harness', 'preload-perl'], 'global services alphabetical');
is([$log->services(0)], ['run'], 'run-scoped services');
is([$log->runs], [0, 2], 'runs ascending integer');
is([$log->jobs(0)], [0, 1], 'jobs ascending');
is([$log->tries(0, 0)], [0, 1], 'tries ascending');
is($log->last_try(0, 0), 1, 'last_try -> highest');
is($log->last_try(0, 1), 0, 'last_try when only one');

ok($log->has_run(0), 'has_run 0');
ok($log->has_run(2), 'has_run 2');
ok(!$log->has_run(7), '!has_run 7');
ok(!$log->has_run('garbage'), '!has_run on non-numeric');
ok($log->has_job(0, 0), 'has_job');
ok(!$log->has_job(0, 99), '!has_job 0/99');
ok($log->has_try(0, 0, 1), 'has_try');
ok(!$log->has_try(0, 0, 7), '!has_try');
ok($log->has_service('harness'), 'has_service harness');
ok($log->has_service('preload-perl'), 'has_service preload-perl');
ok(!$log->has_service('zzz'), '!has_service zzz');
ok($log->has_service('run', 0), 'has_service run @ run 0');
ok(!$log->has_service('run', 2), '!has_service run @ run 2');

# Throws on missing parent
like(dies { $log->jobs(99) },     qr/no such run/, 'jobs on missing run croaks');
like(dies { $log->tries(0, 99) }, qr/no such job/, 'tries on missing job croaks');
like(dies { $log->services(99) }, qr/no such run/, 'services on missing run croaks');

done_testing;
