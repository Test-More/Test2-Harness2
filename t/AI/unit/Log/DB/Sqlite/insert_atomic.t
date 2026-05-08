use Test2::V0;
use Test2::Require::Module 'DBD::SQLite';
use Test2::Require::AuthorTesting;

use File::Temp qw/tempdir tempfile/;
use File::Path qw/make_path/;

use Test2::Harness2::Util::JSON qw/encode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
use App::Yath2::Log;
use App::Yath2::DB;

use lib 't/lib';
use Test2::Harness2::Test::DBVersions qw/for_each_log_db_backend/;

# B8 (D6): insert() wraps the entire population pass in a DB
# transaction. Any mid-insert die rolls back; the source's
# archive_uuid carries over verbatim (D5+D6) so re-importing the
# same source raises a clean error instead of silently duplicating.

# Helper: build a minimal source dir with a fixed archive_uuid.
sub build_source {
    my (%args) = @_;
    my $uuid = $args{archive_uuid};
    my $src  = tempdir(CLEANUP => 1);
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

    if (defined $uuid) {
        my $meta = {
            format_version => 1,
            archive_uuid   => $uuid,
            created_at     => '2025-02-01T00:00:00Z',
            host           => 'b8-host',
            user           => 'b8',
            project        => 'b8-test',
            yath_version   => '2.000099',
        };
        open(my $fh, '>', "$src/meta.json") or die $!;
        binmode $fh;
        print $fh encode_json($meta);
        close $fh;
    }
    return $src;
}

for_each_log_db_backend(sub {
    my ($backend) = @_;

    my $fresh_db = sub {
        my (undef, $db_path) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
        unlink $db_path;
        return App::Yath2::DB->open(dsn => "dbi:SQLite:$db_path", backend => $backend);
    };

    # {{{ Test 1: duplicate-uuid rejection.
    # Inserting the same source twice fails on the second call with a
    # clean error and leaves the archives table at exactly 1 row.
    {
        my $uuid = '019D2B1A-8000-7000-8000-CAFEBABE1001';
        my $src  = build_source(archive_uuid => $uuid);
        my $db   = $fresh_db->();

        my $aid = $db->insert(App::Yath2::Log->new(dir => $src));
        ok(defined $aid, 'first insert succeeds');

        my $err;
        my $ok = eval {
            $db->insert(App::Yath2::Log->new(dir => $src));
            1;
        };
        $err = $@;
        ok(!$ok, 're-insert dies');
        like($err, qr/already exists; not re-imported/,
            'clean error message');

        my ($n) = $db->dbh->selectrow_array(
            q{SELECT count(*) FROM archives});
        is($n, 1, 'exactly one archives row -- re-import did not partially populate');
    }
    # }}}

    # {{{ Test 2: atomic rollback.
    # If a helper called inside the transaction body dies, the entire
    # insert rolls back: archives, runs, jobs, job_tries, services,
    # service_lifetimes, subtests, artifacts, test_files, job_specs all
    # remain empty.
    {
        my $src = build_source();    # live-dir source -- mints fresh uuid
        my $db  = $fresh_db->();

        # Monkey-patch _populate_summary_rows on the Internal base
        # (raw-SQL helper). Both backends route through it: the dbic
        # backend forwards insert() to its Internal helper, so the
        # patch covers it too.
        no warnings 'redefine';
        my $orig = \&App::Yath2::DB::Internal::_populate_summary_rows;
        local *App::Yath2::DB::Internal::_populate_summary_rows = sub {
            die "synthetic mid-insert failure\n";
        };

        my $ok = eval { $db->insert(App::Yath2::Log->new(dir => $src)); 1 };
        my $err = $@;
        ok(!$ok, 'insert dies when inner helper dies');
        like($err, qr/synthetic mid-insert failure/,
            'original error is propagated');

        my $dbh = $db->dbh;
        for my $table (qw/
            archives runs jobs job_tries services service_lifetimes
            subtests artifacts test_files job_specs
        /) {
            my ($n) = $dbh->selectrow_array("SELECT count(*) FROM $table");
            is($n, 0, "$table empty after rollback");
        }

        # Restore and retry: the same source inserts cleanly with no
        # leftover state.
        local *App::Yath2::DB::Internal::_populate_summary_rows = $orig;
        my $aid = eval { $db->insert(App::Yath2::Log->new(dir => $src)) };
        ok(defined $aid, 'retry after rollback succeeds');
        my ($n) = $dbh->selectrow_array(q{SELECT count(*) FROM archives});
        is($n, 1, 'one archives row after retry');
    }
    # }}}

    # {{{ Test 3: explicit archive_uuid override wins over source meta.
    {
        my $src_uuid = '019D2B1A-8000-7000-8000-CAFEBABE3001';
        my $ovr_uuid = '019D2B1A-8000-7000-8000-CAFEBABE3002';
        my $src      = build_source(archive_uuid => $src_uuid);
        my $db       = $fresh_db->();

        my $aid = $db->insert(
            App::Yath2::Log->new(dir => $src),
            archive_uuid => $ovr_uuid,
        );
        ok(defined $aid, 'override insert succeeds');

        my ($got) = $db->dbh->selectrow_array(
            q{SELECT archive_uuid FROM archives WHERE archive_id = ?},
            undef, $aid,
        );
        is(uc($got), uc($ovr_uuid),
            'override archive_uuid wins over source meta (D6)');
    }
    # }}}
});

done_testing;
