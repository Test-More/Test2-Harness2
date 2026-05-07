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
    $admin->do('CREATE DATABASE IF NOT EXISTS yath_log_test_archver');
    $admin->disconnect;
    }
    my $dsn = $qdb->connect_string('yath_log_test_archver');

    sub build_minimal_log {
    my $src = tempdir(CLEANUP => 1);
    make_path("$src/services/harness");
    make_path("$src/runs/0");
    make_path("$src/runs/0/jobs/0/0");

    for my $base ('services/harness', 'runs/0', 'runs/0/jobs/0/0') {
        my $w = open_zstd_writer("$src/$base/events.jsonl.zst");
        $w->say(encode_json({ping => 1}));
        $w->close;
    }

    my $w = open_zstd_writer("$src/runs/0/jobs/0/0/spec.jsonl.zst");
    $w->say(encode_json({relative => 't/dummy.t'}));
    $w->close;

    return $src;
    }

    my $writer = App::Yath2::Log::MariaDB->new(dsn => $dsn);
    $writer->bootstrap_schema;

    my $src = build_minimal_log();
    my $aid = $writer->insert(App::Yath2::Log->new(dir => $src));
    ok(defined $aid, 'insert returned an archive_id');

    my ($stamped_version) = $writer->dbh->selectrow_array(
    'SELECT archive_version FROM archives WHERE archive_id = ?',
    undef, $aid,
    );
    is($stamped_version, $App::Yath2::Log::VERSION,
    'archive_version stamped to $App::Yath2::Log::VERSION on insert');

    # Reader on the same DB resolves at construction.
    {
    my $reader;
    ok(
        lives { $reader = App::Yath2::Log::MariaDB->new(dsn => $dsn) },
        'reader opens at current version',
    );
    is([$reader->runs], [0], 'reader sees the run');
    }

    # Stamp an old archive_version and confirm read-side refusal.
    $writer->dbh->do(
    'UPDATE archives SET archive_version = ? WHERE archive_id = ?',
    undef, '2.000010', $aid,
    );

    like(
    dies { App::Yath2::Log::MariaDB->new(dsn => $dsn) },
    qr/refusing to read/,
    'reader refuses archive whose archive_version < last_breaking_version',
    );

    # Reset; reader works again.
    $writer->dbh->do(
    'UPDATE archives SET archive_version = ? WHERE archive_id = ?',
    undef, $App::Yath2::Log::VERSION, $aid,
    );
    ok(
    lives { App::Yath2::Log::MariaDB->new(dsn => $dsn) },
    'reader works once archive_version is back at current',
    );

});

done_testing;
