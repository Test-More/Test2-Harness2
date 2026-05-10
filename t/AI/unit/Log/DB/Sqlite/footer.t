use Test2::V0;
use Test2::Require::Module 'DBD::SQLite';
use Test2::Require::AuthorTesting;

use File::Temp qw/tempdir tempfile/;
use File::Path qw/make_path/;
use Test2::Harness2::Util::JSON qw/encode_json decode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;

use App::Yath2::Log;
use App::Yath2::DB;
use App::Yath2::Log::Footer qw{
    FOOTER_SIZE
    FORMAT_ID_SQL
    FLAG_META_COMPRESSED
    has_footer
    read_footer_from_path
    read_meta_from_path
};

use lib 't/lib';
use Test2::Harness2::Test::DBVersions qw/for_each_log_db_backend/;

# F3: Log::Sqlite->insert(seal => 1) appends a YATHFOOT trailer +
# zstd-compressed copy of meta.json past the SQLite body. SQLite stays
# readable (raw DBI works), and a sealed Log instance refuses further
# inserts.

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

    # --- Part 1: seal => 1 appends YATHFOOT + meta ---
    {
        my $src = build_minimal_log();
        my (undef, $path) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
        unlink $path;

        my $sq = App::Yath2::DB->open(file => $path, backend => $backend);
        my $dir_log = App::Yath2::Log->new(dir => $src);
        my $aid = $sq->insert($dir_log, seal => 1);
        ok(defined $aid, 'seal => 1 insert returned an archive_id');

        ok(has_footer($path), 'sealed file has YATHFOOT footer');

        my $f = read_footer_from_path($path);
        ok($f, 'read_footer_from_path returns a hashref');
        is($f->{format_id}, FORMAT_ID_SQL,             'format_id is SQL');
        ok($f->{flags} & FLAG_META_COMPRESSED,         'meta payload is compressed');
        is($f->{format_ptr}, 0,                        'format_ptr is 0 (no secondary pointer)');
        ok($f->{body_size}  > 0,                       'body_size > 0');
        ok($f->{meta_size}  > 0,                       'meta_size > 0');
        ok($f->{meta_offset} >= $f->{body_size},
            'meta_offset is at or past the SQLite body');

        my ($meta_bytes, $f2) = read_meta_from_path($path);
        my $meta = decode_json($meta_bytes);
        ok(defined $meta->{archive_uuid}, 'meta has archive_uuid');

        require DBI;
        my $dbh = DBI->connect("dbi:SQLite:$path", undef, undef, {
            RaiseError => 1, PrintError => 0, AutoCommit => 1,
        });
        my ($cnt) = $dbh->selectrow_array('SELECT COUNT(*) FROM archives');
        is($cnt, 1, 'raw DBI: archives table has exactly 1 row');

        my ($row_uuid) = $dbh->selectrow_array(
            'SELECT archive_uuid FROM archives WHERE archive_id = ?', undef, $aid,
        );
        is($row_uuid, $meta->{archive_uuid},
            'trailer-extracted meta uuid matches archives.archive_uuid');
        $dbh->disconnect;

        my $disk = -s $path;
        is($disk, $f->{body_size} + $f->{meta_size} + FOOTER_SIZE,
            'on-disk size = body_size + meta_size + FOOTER_SIZE');

        # +SEALED slot prevents further inserts on the same instance.
        my $err;
        my $ok = eval { $sq->insert($dir_log); 1 };
        $err = $@;
        ok(!$ok, 'second insert on sealed instance fails');
        like($err, qr/sealed/i, 'error message mentions sealed');
    }

    # --- Part 2: default (no seal) does NOT append a footer ---
    {
        my $src = build_minimal_log();
        my (undef, $path) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
        unlink $path;

        my $sq = App::Yath2::DB->open(file => $path, backend => $backend);
        my $dir_log = App::Yath2::Log->new(dir => $src);
        my $aid = $sq->insert($dir_log);   # no seal
        ok(defined $aid, 'unsealed insert returned an archive_id');

        ok(!has_footer($path),
            'no YATHFOOT footer when seal => 1 not passed (default)');

        ok(!$sq->sealed, 'sealed slot stays false on unsealed instance');
    }

    # --- Part 3: Directory->archive(format=>'sqlite') triggers the seal ---
    {
        my $src = build_minimal_log();
        my (undef, $path) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
        unlink $path;

        my $dir_log = App::Yath2::Log->new(dir => $src);
        $dir_log->archive($path, format => 'sqlite');

        ok(has_footer($path),
            'Directory->archive(format=>sqlite) appends YATHFOOT trailer');

        my $f = read_footer_from_path($path);
        is($f->{format_id}, FORMAT_ID_SQL, 'format_id is SQL');
    }
});

done_testing;
