use Test2::V0;
use Test2::Require::Module 'DBD::SQLite';

use File::Temp qw/tempdir tempfile/;
use File::Path qw/make_path/;

use Test2::Harness2::Util::JSON qw/encode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
use App::Yath2::Log;
use App::Yath2::Log::Sqlite;

# Build a synthetic log directory and archive it to a SQLite .yath
# file. The test suite mirrors the TarZIdx listing test so the same
# expectations exercise both backends.
my $src = tempdir(CLEANUP => 1);
make_path("$src/services/harness");
make_path("$src/services/preload-perl");
make_path("$src/runs/0/services/run");
make_path("$src/runs/0/jobs/0/0");
make_path("$src/runs/0/jobs/0/1");
make_path("$src/runs/0/jobs/1/0");
make_path("$src/runs/2/jobs/0/0");

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

my (undef, $arc_path) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
unlink $arc_path;
App::Yath2::Log->new(dir => $src)->archive($arc_path, format => 'sqlite');

my $log = App::Yath2::Log->new(file => $arc_path);
isa_ok($log, ['App::Yath2::Log::Sqlite']);

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

# Multi-archive ambiguity (per F11): inserting a second archive into
# the same SQLite forces the caller to pass uuid => ... on reopen.
{
    my $src2 = tempdir(CLEANUP => 1);
    make_path("$src2/services/harness");
    my $w = open_zstd_writer("$src2/services/harness/events.jsonl.zst");
    $w->say(encode_json({ping => 'archive2'}));
    $w->close;

    my $writer = App::Yath2::Log::Sqlite->new(file => $arc_path);
    $writer->insert(App::Yath2::Log->new(dir => $src2));

    like(
        dies { App::Yath2::Log->new(file => $arc_path) },
        qr/ambiguous; specify uuid =>/,
        'multi-archive .yath without uuid throws',
    );

    my $u = $writer->uuid;
    my $picked = App::Yath2::Log->new(file => $arc_path, uuid => $u);
    isa_ok($picked, ['App::Yath2::Log::Sqlite']);
}

# 0-archive case: a fresh empty file is allowed (writers need to open
# before the first insert), but reads throw "no archives in this DB".
{
    my (undef, $empty) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
    unlink $empty;
    my $writer = App::Yath2::Log::Sqlite->new(file => $empty);
    isa_ok($writer, ['App::Yath2::Log::Sqlite']);

    like(dies { $writer->runs }, qr/no archives in this DB/,
        'reads on empty DB throw');
}

done_testing;
