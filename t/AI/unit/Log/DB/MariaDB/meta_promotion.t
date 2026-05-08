use Test2::V0;
use Test2::Require::Module 'DBD::MariaDB';
use Test2::Require::Module 'DBIx::QuickDB';
use Test2::Require::Module 'Test2::Tools::QuickDB';

use Test2::Tools::QuickDB;
use lib 't/lib';
use Test2::Harness2::Test::DBVersions qw/for_each_db_version get_quiet_db for_each_log_db_backend/;
for_each_db_version([qw/mariadb/], sub {
    for_each_log_db_backend(sub {
        my ($backend) = @_;
    skipall_unless_can_db(driver => 'MariaDB');

    use File::Temp qw/tempdir/;
    use File::Path qw/make_path/;
    use DBI ();

    use Test2::Harness2::Util::JSON qw/encode_json decode_json/;
    use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
    use App::Yath2::Log;
    use App::Yath2::DB;
    my $qdb = get_quiet_db({ driver => 'MariaDB' });
    {
    my $admin = DBI->connect(
        $qdb->connect_string, undef, undef,
        { RaiseError => 1, PrintError => 0, AutoCommit => 1 },
    ) or die "connect: $DBI::errstr";
    $admin->do('CREATE DATABASE IF NOT EXISTS yath_log_test_metapromotion');
    $admin->disconnect;
    }
    my $dsn = $qdb->connect_string('yath_log_test_metapromotion');

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

    my $db = App::Yath2::DB->open(dsn => $dsn, backend => $backend);
    $db->bootstrap_schema;

    my $src = build_minimal_log();
    my $aid = $db->insert(App::Yath2::Log->new(dir => $src));
    ok(defined $aid, 'insert returned an archive_id');

    my $dbh = $db->dbh;

    my ($n) = $dbh->selectrow_array(q{
    SELECT count(*) FROM artifacts
     WHERE archive_id = ? AND artifact_kind = 'arbitrary' AND name = 'meta.json'
    }, undef, $aid);
    is($n, 0, 'no meta.json artifact row');

    $dbh->do(q{
    DELETE FROM artifacts
     WHERE archive_id = ? AND artifact_kind = 'arbitrary' AND name = 'meta.json'
    }, undef, $aid);

    my $log  = App::Yath2::DB->open(dsn => $dsn, backend => $backend);
    my $root = $log->artifacts;
    ok($root->exists('meta.json'), 'meta.json visible at archive root');

    my $bytes = $root->get('meta.json');
    my $meta = decode_json($bytes);
    like($meta->{archive_uuid}, qr/^[0-9A-Fa-f-]{36}$/, 'archive_uuid shape');
    ok(defined $meta->{host},         'host present');
    ok(defined $meta->{user},         'user present');
    ok(defined $meta->{yath_version}, 'yath_version present');
    is($meta->{format_version}, 1,    'format_version via meta_extras');
    like($meta->{created_at}, qr/^\d{4}-\d{2}-\d{2}T/, 'created_at ISO shape');

    my $row = $dbh->selectrow_hashref(q{
    SELECT host, "user" AS user_, git_sha, project, yath_version,
           sealed_at, meta_extras
      FROM archives WHERE archive_id = ?
    }, undef, $aid);
    ok(defined $row->{host},         'archives.host populated');
    ok(defined $row->{user_},        'archives."user" populated');
    ok(defined $row->{yath_version}, 'archives.yath_version populated');
    ok(defined $row->{sealed_at},    'archives.sealed_at non-null');
    ok(defined $row->{meta_extras},  'meta_extras populated');

    my $extras = decode_json($row->{meta_extras});
    is($extras->{format_version}, 1,     'format_version in meta_extras');
    ok(!exists $extras->{archive_uuid},  'archive_uuid not duplicated');
    ok(!exists $extras->{host},          'host not duplicated');

    });
});

done_testing;
