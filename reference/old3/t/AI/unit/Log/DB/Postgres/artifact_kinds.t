use Test2::V0;
use Test2::Require::Module 'DBD::Pg';
use Test2::Require::Module 'DBIx::QuickDB';
use Test2::Require::Module 'Test2::Tools::QuickDB';

use Test2::Tools::QuickDB;
use lib 't/lib';
use Test2::Harness2::Test::DBVersions qw/for_each_db_version get_quiet_db for_each_log_db_backend/;
for_each_db_version([qw/postgresql/], sub {
    for_each_log_db_backend(sub {
        my ($backend) = @_;
    skipall_unless_can_db(driver => 'PostgreSQL');

    use File::Temp qw/tempdir/;
    use File::Path qw/make_path/;
    use DBI ();

    use Test2::Util::UUID qw/gen_uuid/;
    use Test2::Harness2::Util::JSON qw/encode_json/;
    use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
    use App::Yath2::Log;
    use App::Yath2::DB;
    my $qdb = get_quiet_db({ driver => 'PostgreSQL' });
    {
    my $admin = DBI->connect(
        $qdb->connect_string('postgres'), undef, undef,
        { RaiseError => 1, PrintError => 0, AutoCommit => 1, pg_enable_utf8 => 1 },
    ) or die "connect: $DBI::errstr";
    eval { $admin->do('CREATE DATABASE yath_log_test_artifactkinds'); };
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

    my $db = App::Yath2::DB->open(dsn => $dsn, backend => $backend);
    $db->bootstrap_schema;

    my $aid = $db->insert(App::Yath2::Log->new(dir => build_source()));
    ok(defined $aid, 'insert succeeded');

    my $dbh  = $db->dbh;
    my $rows = $dbh->selectall_arrayref(q{
    SELECT DISTINCT artifact_kind::text AS k
      FROM artifacts ORDER BY k
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

# Schema-side defense: the ENUM rejects dropped values at parse time.
for my $bad (qw(spec report state)) {
    my $err;
    my $ok = eval {
        $dbh->do(q{
            INSERT INTO artifacts
                (archive_id, artifact_uuid, artifact_kind, format,
                 name, compressed, payload, created_at)
            VALUES (?, ?, ?::artifact_kind_t, 'jsonl', NULL, FALSE, ?, ?)
        }, undef, $aid, gen_uuid(), $bad, '{}', '2025-01-01T00:00:00Z');
        1;
    };
    $err = $@;
    ok(!$ok, "INSERT with artifact_kind='$bad' is rejected");
    like(
        $err // '',
        qr/(?:check|constraint|enum|invalid)/i,
        "rejection for '$bad' mentions check/constraint/enum/invalid",
    );
}

    });
});

done_testing;
