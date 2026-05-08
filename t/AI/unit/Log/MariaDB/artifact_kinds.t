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

    use Test2::Util::UUID qw/gen_uuid/;
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
    $admin->do('CREATE DATABASE IF NOT EXISTS yath_log_test_artifactkinds');
    $admin->disconnect;
    }
    my $dsn = $qdb->connect_string('yath_log_test_artifactkinds');

    # B9: insert() no longer writes spec/report/state artifact rows. The
    # artifact_kind ENUM allows only 'events','attachment','arbitrary'.

    sub build_source {
    my $src = tempdir(CLEANUP => 1);
    make_path("$src/services/harness");
    make_path("$src/runs/0");
    make_path("$src/runs/0/jobs/0/0");

    for my $base ('services/harness', 'runs/0', 'runs/0/jobs/0/0') {
        my $w = open_zstd_writer("$src/$base/events.jsonl.zst");
        $w->say(encode_json({ping => 1}));
        $w->close;
    }

    for my $base ('services/harness', 'runs/0', 'runs/0/jobs/0/0') {
        my $w = open_zstd_writer("$src/$base/spec.jsonl.zst");
        $w->say(encode_json({relative => 't/dummy.t', kind => 'spec'}));
        $w->close;

        $w = open_zstd_writer("$src/$base/report.jsonl.zst");
        $w->say(encode_json({pass => 1, kind => 'report'}));
        $w->close;
    }

    make_path("$src/services/harness/attachments");
    open(my $a, '>', "$src/services/harness/attachments/0001-hello.txt") or die $!;
    print $a "hi\n";
    close $a;

    return $src;
    }

    my $db = App::Yath2::Log::MariaDB->new(dsn => $dsn);
    $db->bootstrap_schema;

    my $aid = $db->insert(App::Yath2::Log->new(dir => build_source()));
    ok(defined $aid, 'insert succeeded');

    my $dbh  = $db->dbh;
    my $rows = $dbh->selectall_arrayref(q{
    SELECT DISTINCT artifact_kind FROM artifacts ORDER BY artifact_kind
});
my @kinds = map { $_->[0] } @$rows;

ok(!(grep { $_ eq 'spec'   } @kinds), 'no spec artifact rows');
ok(!(grep { $_ eq 'state'  } @kinds), 'no state artifact rows');
ok(!(grep { $_ eq 'report' } @kinds), 'no report artifact rows');

for my $k (@kinds) {
    ok(
        (grep { $_ eq $k } qw(events attachment arbitrary)),
        "kind '$k' is one of (events, attachment, arbitrary)",
    );
}

ok((grep { $_ eq 'events'     } @kinds), 'has events artifact rows');
ok((grep { $_ eq 'attachment' } @kinds), 'has attachment artifact rows');

# Schema-side defense: the ENUM rejects dropped values. By default
# MariaDB inserts the empty string for an out-of-range ENUM value
# (with a warning). Force STRICT_ALL_TABLES at the session level so
# the bad value becomes a hard error.
$dbh->do(q{SET SESSION sql_mode = 'STRICT_ALL_TABLES'});

for my $bad (qw(spec report state)) {
    my $err;
    my $ok = eval {
        my $sth = $dbh->prepare(q{
            INSERT INTO artifacts
                (archive_id, artifact_uuid, artifact_kind, format,
                 name, compressed, payload, created_at)
            VALUES (?, ?, ?, 'jsonl', NULL, 0, ?, NOW(6))
        });
        $sth->bind_param(1, $aid);
        $sth->bind_param(2, gen_uuid());
        $sth->bind_param(3, $bad);
        $sth->bind_param(4, '{}');
        $sth->execute;
        1;
    };
    $err = $@;
    ok(!$ok, "INSERT with artifact_kind='$bad' is rejected");
    like(
        $err // '',
        qr/(?:check|constraint|enum|invalid|truncat|incorrect)/i,
        "rejection for '$bad' mentions check/constraint/enum/invalid",
    );
}

});

done_testing;
