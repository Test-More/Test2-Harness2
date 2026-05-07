use Test2::V0;
use Test2::Require::Module 'DBD::MariaDB';
use Test2::Require::Module 'DBIx::QuickDB';
use Test2::Require::Module 'Test2::Tools::QuickDB';

use Test2::Tools::QuickDB;
use lib 't/lib';
use Test2::Harness2::Test::DBVersions qw/for_each_db_version/;
for_each_db_version([qw/mariadb/], sub {
    skipall_unless_can_db(driver => 'MariaDB');

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use DBI ();

use Test2::Harness2::Util::JSON qw/encode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
use App::Yath2::Log;
use App::Yath2::Log::MariaDB;

my $qdb = get_db({ driver => 'MariaDB' });
{
    my $admin = DBI->connect(
        $qdb->connect_string, undef, undef,
        { RaiseError => 1, PrintError => 0, AutoCommit => 1 },
    ) or die "connect: $DBI::errstr";
    $admin->do('CREATE DATABASE IF NOT EXISTS yath_log_test_listing');
    $admin->disconnect;
}
my $dsn = $qdb->connect_string('yath_log_test_listing');

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

# spec.jsonl for each job try -- required now that jobs.test_file_id is NOT NULL.
for my $pair (
    ['runs/0/jobs/0/0', 't/job0.t'],
    ['runs/0/jobs/0/1', 't/job0.t'],
    ['runs/0/jobs/1/0', 't/job1.t'],
    ['runs/2/jobs/0/0', 't/job2.t'],
) {
    my ($base, $rel) = @$pair;
    my $w = open_zstd_writer("$src/$base/spec.jsonl.zst");
    $w->say(encode_json({relative => $rel}));
    $w->close;
}

my $writer = App::Yath2::Log::MariaDB->new(dsn => $dsn);
$writer->insert(App::Yath2::Log->new(dir => $src));

my $log = App::Yath2::Log::MariaDB->new(dsn => $dsn);
isa_ok($log, ['App::Yath2::Log::MariaDB']);

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

like(dies { $log->jobs(99) },     qr/no such run/, 'jobs on missing run croaks');
like(dies { $log->tries(0, 99) }, qr/no such job/, 'tries on missing job croaks');
like(dies { $log->services(99) }, qr/no such run/, 'services on missing run croaks');

# Multi-archive: insert another and verify the ambiguity error.
{
    my $src2 = tempdir(CLEANUP => 1);
    make_path("$src2/services/harness");
    my $w = open_zstd_writer("$src2/services/harness/events.jsonl.zst");
    $w->say(encode_json({ping => 'archive2'}));
    $w->close;

    my $w2 = App::Yath2::Log::MariaDB->new(dsn => $dsn);
    $w2->insert(App::Yath2::Log->new(dir => $src2));

    like(
        dies { App::Yath2::Log::MariaDB->new(dsn => $dsn)->runs },
        qr/ambiguous; specify uuid =>/,
        'multi-archive without uuid throws',
    );

    my $u = $w2->uuid;
    my $picked = App::Yath2::Log::MariaDB->new(dsn => $dsn, uuid => $u);
    isa_ok($picked, ['App::Yath2::Log::MariaDB']);
}

# 0-archive case: a fresh empty DB is allowed; reads throw.
{
    my $admin = DBI->connect(
        $qdb->connect_string, undef, undef,
        { RaiseError => 1, PrintError => 0, AutoCommit => 1 },
    );
    $admin->do('CREATE DATABASE IF NOT EXISTS yath_log_test_listing_empty');
    $admin->disconnect;

    my $empty = $qdb->connect_string('yath_log_test_listing_empty');
    my $w = App::Yath2::Log::MariaDB->new(dsn => $empty);
    isa_ok($w, ['App::Yath2::Log::MariaDB']);
    like(dies { $w->runs }, qr/no archives in this DB/, 'reads on empty DB throw');
}

});

done_testing;
