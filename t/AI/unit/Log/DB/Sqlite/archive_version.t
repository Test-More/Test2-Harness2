use Test2::V0;
use Test2::Require::Module 'DBD::SQLite';

use File::Temp qw/tempdir tempfile/;
use File::Path qw/make_path/;

use Test2::Harness2::Util::JSON qw/encode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
use App::Yath2::Log;
use App::Yath2::DB;

use lib 't/lib';
use Test2::Harness2::Test::DBVersions qw/for_each_log_db_backend/;

# Build a minimal synthetic log directory: one global service and one run
# with one job/try. Enough for a complete archive round-trip.
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

for_each_log_db_backend(sub {
    my ($backend) = @_;

    # --- Build an archive and confirm a current archive_version was stamped.
    my (undef, $db_path) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
    unlink $db_path;

    my $writer = App::Yath2::DB->open(dsn => "dbi:SQLite:$db_path", backend => $backend);
    $writer->bootstrap_schema;

    my $src = build_minimal_log();
    my $aid = $writer->insert(App::Yath2::Log->new(dir => $src));
    ok(defined $aid, 'insert returned an archive_id');

    my $stamped_version = $writer->dbh->selectrow_array(
        'SELECT archive_version FROM archives WHERE archive_id = ?',
        undef, $aid,
    );
    is($stamped_version, $App::Yath2::Log::VERSION,
        'archive_version stamped to $App::Yath2::Log::VERSION on insert');

    # A fresh reader on the same DB resolves the archive at construction.
    {
        my $reader;
        ok(
            lives { $reader = App::Yath2::DB->open(dsn => "dbi:SQLite:$db_path", backend => $backend) },
            'reader opens at current version',
        );
        is([$reader->runs], [0], 'reader sees the run');
    }

    # --- Stamp an old archive_version and confirm read-side refusal.
    $writer->dbh->do(
        'UPDATE archives SET archive_version = ? WHERE archive_id = ?',
        undef, '2.000010', $aid,
    );

    like(
        dies { App::Yath2::DB->open(dsn => "dbi:SQLite:$db_path", backend => $backend)->runs },
        qr/refusing to read/,
        'reader refuses archive whose archive_version < last_breaking_version',
    );

    # --- Reset the version to current; reader works again.
    $writer->dbh->do(
        'UPDATE archives SET archive_version = ? WHERE archive_id = ?',
        undef, $App::Yath2::Log::VERSION, $aid,
    );

    ok(
        lives { App::Yath2::DB->open(dsn => "dbi:SQLite:$db_path", backend => $backend) },
        'reader works once archive_version is back at current',
    );

    # --- An archive at exactly last_breaking_version is accepted.
    $writer->dbh->do(
        'UPDATE archives SET archive_version = ? WHERE archive_id = ?',
        undef, App::Yath2::Log->last_breaking_version, $aid,
    );

    ok(
        lives { App::Yath2::DB->open(dsn => "dbi:SQLite:$db_path", backend => $backend) },
        'reader accepts archive_version == last_breaking_version',
    );
});

done_testing;
