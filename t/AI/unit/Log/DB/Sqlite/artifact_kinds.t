use Test2::V0;
use Test2::Require::Module 'DBD::SQLite';

use File::Temp qw/tempdir tempfile/;
use File::Path qw/make_path/;

use Test2::Util::UUID qw/gen_uuid/;
use Test2::Harness2::Util::JSON qw/encode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
use App::Yath2::Log;
use App::Yath2::Log::DB::Sqlite;

# B9: insert() no longer writes spec.jsonl / report.jsonl / state.jsonl
# as artifact rows. The artifact_kind CHECK constraint now allows only
# 'events', 'attachment', and 'arbitrary'. Reconstruction reads spec /
# report from typed columns + extras at read time.

sub build_source {
    my $src = tempdir(CLEANUP => 1);
    make_path("$src/services/harness");
    make_path("$src/runs/0");
    make_path("$src/runs/0/jobs/0/0");

    # events streams at every scope.
    for my $base ('services/harness', 'runs/0', 'runs/0/jobs/0/0') {
        my $w = open_zstd_writer("$src/$base/events.jsonl.zst");
        $w->say(encode_json({ping => 1}));
        $w->close;
    }

    # spec/report at every scope so the source has bytes to be dropped.
    for my $base ('services/harness', 'runs/0', 'runs/0/jobs/0/0') {
        my $w = open_zstd_writer("$src/$base/spec.jsonl.zst");
        $w->say(encode_json({relative => 't/dummy.t', kind => 'spec'}));
        $w->close;

        $w = open_zstd_writer("$src/$base/report.jsonl.zst");
        $w->say(encode_json({pass => 1, kind => 'report'}));
        $w->close;
    }

    # An attachment at the harness service scope.
    make_path("$src/services/harness/attachments");
    open(my $a, '>', "$src/services/harness/attachments/0001-hello.txt") or die $!;
    print $a "hi\n";
    close $a;

    return $src;
}

# {{{ insert produces only events / attachment / arbitrary kinds.
{
    my (undef, $db_path) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
    unlink $db_path;
    my $db = App::Yath2::Log::DB::Sqlite->new(dsn => "dbi:SQLite:$db_path");
    $db->bootstrap_schema;

    my $aid = $db->insert(App::Yath2::Log->new(dir => build_source()));
    ok(defined $aid, 'insert succeeded');

    my $dbh = $db->dbh;
    my $kinds = $dbh->selectall_arrayref(q{
        SELECT DISTINCT artifact_kind FROM artifacts ORDER BY artifact_kind
    });
    my @kinds = map { $_->[0] } @$kinds;

    # No spec / state / report rows.
    ok(!(grep { $_ eq 'spec'   } @kinds), 'no spec artifact rows');
    ok(!(grep { $_ eq 'state'  } @kinds), 'no state artifact rows');
    ok(!(grep { $_ eq 'report' } @kinds), 'no report artifact rows');

    # Every kind we DO see is one of the three allowed values.
    for my $k (@kinds) {
        ok(
            (grep { $_ eq $k } qw(events attachment arbitrary)),
            "kind '$k' is one of (events, attachment, arbitrary)",
        );
    }

    # We must at least have events rows; the attachment we added should
    # also be present.
    ok((grep { $_ eq 'events'     } @kinds), 'has events artifact rows');
    ok((grep { $_ eq 'attachment' } @kinds), 'has attachment artifact rows');
}
# }}}

# {{{ Schema-side defense: CHECK rejects 'spec' / 'report' / 'state'.
{
    my (undef, $db_path) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
    unlink $db_path;
    my $db = App::Yath2::Log::DB::Sqlite->new(dsn => "dbi:SQLite:$db_path");
    $db->bootstrap_schema;
    my $aid = $db->insert(App::Yath2::Log->new(dir => build_source()));
    my $dbh = $db->dbh;

    for my $bad (qw(spec report state)) {
        my $err;
        my $ok = eval {
            $dbh->do(q{
                INSERT INTO artifacts
                    (archive_id, artifact_uuid, artifact_kind, format,
                     name, compressed, payload, created_at)
                VALUES (?, ?, ?, 'jsonl', NULL, 0, ?, ?)
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
}
# }}}

done_testing;
