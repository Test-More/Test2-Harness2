use Test2::V0;
use Test2::Require::Module 'DBD::SQLite';
use Test2::Require::AuthorTesting;

use File::Temp qw/tempdir tempfile/;
use File::Path qw/make_path/;

use Test2::Harness2::Util::JSON qw/encode_json decode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
use App::Yath2::Log;
use App::Yath2::DB;
use App::Yath2::Log::DB;

use lib 't/lib';
use Test2::Harness2::Test::DBVersions qw/for_each_log_db_backend/;

# B7: meta.json content is promoted to typed columns on `archives`
# (host, "user", git_sha, project, yath_version) plus a meta_extras
# JSON catch-all. The meta.json artifact row is no longer written;
# reads of meta.json reconstruct from columns. sealed_at carries
# the source's meta.created_at (D5).

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

    # Helper: get the raw-SQL view of $db (for private methods like
    # _db_datetime_to_iso). For internal it's $db; for dbic it's the
    # internal helper sharing the same dbh.
    my $sql = sub {
        my ($db) = @_;
        return $backend eq 'dbic' ? $db->_internal : $db;
    };

    # {{{ Round-trip: insert a fresh source, reconstruct meta.json, assert
    # typed columns populated and content matches.
    {
        my (undef, $db_path) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
        unlink $db_path;
        my $db = App::Yath2::DB->open(dsn => "dbi:SQLite:$db_path", backend => $backend);
        $db->bootstrap_schema;

        my $src = build_minimal_log();
        my $aid = $db->insert(App::Yath2::Log->new(dir => $src));
        ok(defined $aid, 'insert returned an archive_id');

        # No meta.json artifact row should have been written.
        my $dbh = $db->dbh;
        my ($n) = $dbh->selectrow_array(q{
            SELECT count(*) FROM artifacts
             WHERE archive_id = ? AND artifact_kind = 'arbitrary' AND name = 'meta.json'
        }, undef, $aid);
        is($n, 0, 'no meta.json artifact row');

        # Defensive: even if there were one, reconstruction should be the
        # source of truth -- delete and re-read.
        $dbh->do(q{
            DELETE FROM artifacts
             WHERE archive_id = ? AND artifact_kind = 'arbitrary' AND name = 'meta.json'
        }, undef, $aid);

        # Open a fresh DB instance against the same file.
        my $log = App::Yath2::Log->new(file => $db_path);
        my $root = $log->artifacts;
        ok($root->exists('meta.json'), 'meta.json visible at archive root');

        my $bytes = $root->get('meta.json');
        ok(defined $bytes && length $bytes, 'meta.json bytes returned');

        my $meta = decode_json($bytes);
        ok(ref($meta) eq 'HASH', 'meta decodes as hash');
        like($meta->{archive_uuid}, qr/^[0-9A-Fa-f-]{36}$/, 'archive_uuid shape');
        ok(defined $meta->{host}, 'host present in reconstructed meta');
        ok(defined $meta->{user}, 'user present in reconstructed meta');
        ok(defined $meta->{yath_version}, 'yath_version present');
        is($meta->{format_version}, 1, 'format_version round-trips via meta_extras');
        like($meta->{created_at}, qr/^\d{4}-\d{2}-\d{2}T/, 'created_at ISO shape');

        # Raw column inspection: every promoted field is in its own column.
        my $row = $dbh->selectrow_hashref(q{
            SELECT host, "user" AS user_, git_sha, project, yath_version,
                   sealed_at, meta_extras
              FROM archives WHERE archive_id = ?
        }, undef, $aid);
        ok(defined $row->{host},         'archives.host populated');
        ok(defined $row->{user_},        'archives."user" populated');
        ok(defined $row->{yath_version}, 'archives.yath_version populated');
        ok(defined $row->{sealed_at},    'archives.sealed_at non-null');
        is($sql->($db)->_db_datetime_to_iso($row->{sealed_at}), $meta->{created_at},
            'sealed_at equals meta.created_at (D5)');

        ok(defined $row->{meta_extras},
            'meta_extras populated (carries format_version etc.)');

        my $extras = decode_json($row->{meta_extras});
        is($extras->{format_version}, 1,
            'format_version landed in meta_extras (not promoted)');
        ok(!exists $extras->{archive_uuid},
            'archive_uuid not duplicated into meta_extras');
        ok(!exists $extras->{host},
            'host not duplicated into meta_extras');
    }
    # }}}

    # {{{ Carry-over: a hand-crafted source meta.json with a future-key and
    # a fixed created_at. The DB archive's sealed_at must equal the source
    # created_at (D5: carried over verbatim, not stamped fresh). The
    # future-key must round-trip via meta_extras.
    {
        my $src = build_minimal_log();

        # Drop a hand-crafted meta.json into the source root so the
        # insert path picks it up via _resolve_insert_meta.
        my $fixed_created_at = '2025-01-15T00:00:00Z';
        my $source_uuid      = '019D2B1A-8000-7000-8000-CAFEBABE0001';
        my $source_meta = {
            format_version => 1,
            archive_uuid   => $source_uuid,
            created_at     => $fixed_created_at,
            host           => 'test-host.example',
            user           => 'tester',
            git_sha        => 'deadbeef0000000000000000000000000000feed',
            project        => 'carry-over-test',
            yath_version   => '2.000099',
            # A future / unknown key the current dist does not promote.
            harness        => 'something_unknown',
        };
        open(my $mfh, '>', "$src/meta.json") or die $!;
        binmode $mfh;
        print $mfh encode_json($source_meta);
        close $mfh;

        my (undef, $db_path) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
        unlink $db_path;
        my $db = App::Yath2::DB->open(dsn => "dbi:SQLite:$db_path", backend => $backend);
        $db->bootstrap_schema;

        my $aid = $db->insert(App::Yath2::Log->new(dir => $src));
        ok(defined $aid, 'carry-over insert returned an archive_id');

        my $dbh = $db->dbh;
        my $row = $dbh->selectrow_hashref(q{
            SELECT host, "user" AS user_, git_sha, project, yath_version,
                   sealed_at, meta_extras, archive_uuid
              FROM archives WHERE archive_id = ?
        }, undef, $aid);

        is($sql->($db)->_db_datetime_to_iso($row->{sealed_at}), $fixed_created_at,
            'sealed_at carried over from source meta.created_at (D5)');
        is($row->{host},    'test-host.example',     'host carried over');
        is($row->{user_},   'tester',                'user carried over');
        is($row->{git_sha}, 'deadbeef0000000000000000000000000000feed',
            'git_sha carried over');
        is($row->{project},      'carry-over-test', 'project carried over');
        is($row->{yath_version}, '2.000099',        'yath_version carried over');

        is(uc($row->{archive_uuid}), uc($source_uuid),
            'archive_uuid carried over from source meta (D5+D6)');

        my $extras = decode_json($row->{meta_extras});
        is($extras->{format_version}, 1, 'format_version round-trips via meta_extras');
        is($extras->{harness}, 'something_unknown',
            'unknown key round-trips via meta_extras');
        ok(!exists $extras->{archive_uuid}, 'archive_uuid not in meta_extras');
        ok(!exists $extras->{host},         'host not in meta_extras');

        # Reconstructed meta.json restores the unknown key for readers.
        my $log = App::Yath2::Log->new(file => $db_path);
        my $bytes = $log->artifacts->get('meta.json');
        my $meta = decode_json($bytes);
        is($meta->{harness}, 'something_unknown',
            'reconstructed meta.json carries the unknown key');
        is($meta->{format_version}, 1, 'reconstructed meta.json: format_version');
        is($meta->{created_at}, $fixed_created_at,
            'reconstructed meta.json: created_at == source created_at');
        is($meta->{host},    'test-host.example', 'reconstructed: host');
        is($meta->{project}, 'carry-over-test',   'reconstructed: project');
    }
    # }}}
});

done_testing;
