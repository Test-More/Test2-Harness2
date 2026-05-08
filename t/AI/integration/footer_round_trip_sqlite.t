use Test2::V0;
use Test2::Require::Module 'DBD::SQLite';
use Test2::Require::AuthorTesting;

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use Capture::Tiny qw/capture/;

use Test2::Harness2::Util::JSON qw/encode_json decode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;

use App::Yath2::Log;
use App::Yath2::Log::DB::Sqlite;
use App::Yath2::Log::Footer qw{
    FOOTER_SIZE
    FORMAT_ID_SQL
    FLAG_META_COMPRESSED
    has_footer
    read_footer_from_path
    read_meta_from_path
};

# F4 round-trip integration: build a synthetic Log directory, archive
# it to a sealed single-archive SQLite .yath file, and verify both
# yath's own reader (via DBI) and the system `sqlite3` CLI can
# enumerate the archive past the appended YATHFOOT trailer. The
# system sqlite3 block is skipped when `sqlite3` is not on PATH.

sub _which {
    my ($prog) = @_;
    for my $dir (split /:/, ($ENV{PATH} || '')) {
        next unless length $dir;
        my $candidate = "$dir/$prog";
        return $candidate if -x $candidate;
    }
    return undef;
}

# {{{ Build a small live-like source directory.
my $src = tempdir(CLEANUP => 1);
make_path("$src/services/harness");
make_path("$src/runs/0/jobs/0/0");

for my $base ('services/harness', 'runs/0', 'runs/0/jobs/0/0') {
    my $w = open_zstd_writer("$src/$base/events.jsonl.zst");
    $w->say(encode_json({ping => 1}));
    $w->close;
}
{
    my $w = open_zstd_writer("$src/services/harness/spec.jsonl.zst");
    $w->say(encode_json({type => 'Service', id => 'harness'}));
    $w->close;
}
{
    my $w = open_zstd_writer("$src/runs/0/jobs/0/0/spec.jsonl.zst");
    $w->say(encode_json({relative => 't/dummy.t'}));
    $w->close;
}
# }}}

# Archive directory -> sealed single-archive sqlite file. Use a path
# inside a CLEANUP-on-exit tempdir rather than tempfile() so we don't
# race with parallel tests that also pull names from /tmp via
# File::Temp.
my $arc_dir  = tempdir(CLEANUP => 1);
my $arc_path = "$arc_dir/run.yath";
App::Yath2::Log->new(dir => $src)->archive($arc_path, format => 'sqlite');
ok(-s $arc_path, 'archive non-empty');

# {{{ Trailer presence + structure.
ok(has_footer($arc_path), 'sealed archive ends with a YATHFOOT trailer');

my $footer = read_footer_from_path($arc_path);
ok($footer, 'footer parsed');
is($footer->{format_id}, FORMAT_ID_SQL, 'format_id is SQL');
ok($footer->{flags} & FLAG_META_COMPRESSED, 'meta payload is zstd-compressed');
is($footer->{format_ptr}, 0, 'format_ptr is 0 (no secondary pointer)');

my $disk = -s $arc_path;
is(
    $footer->{body_size},
    $disk - $footer->{meta_size} - FOOTER_SIZE,
    'body_size = (file size) - meta_size - FOOTER_SIZE',
);
# }}}

# {{{ Trailer-extracted meta is well-formed JSON with archive_uuid.
my ($meta_bytes, $f2) = read_meta_from_path($arc_path);
ok(length($meta_bytes), 'trailer meta decoded to non-empty bytes');

my $trailer_meta = decode_json($meta_bytes);
ok($trailer_meta->{archive_uuid}, 'trailer meta has archive_uuid');
ok($trailer_meta->{created_at},   'trailer meta has created_at');
# }}}

# {{{ Raw DBI: the trailer doesn't break SQLite.
{
    require DBI;
    my $dbh = DBI->connect("dbi:SQLite:$arc_path", undef, undef, {
        RaiseError => 1, PrintError => 0, AutoCommit => 1,
    });
    my ($cnt) = $dbh->selectrow_array('SELECT COUNT(*) FROM archives');
    is($cnt, 1, 'raw DBI: archives table has exactly 1 row');

    my ($row_uuid) = $dbh->selectrow_array(
        'SELECT archive_uuid FROM archives LIMIT 1');
    is($row_uuid, $trailer_meta->{archive_uuid},
        'archives.archive_uuid matches trailer-extracted meta uuid');
    $dbh->disconnect;
}
# }}}

# {{{ External `sqlite3` CLI verification.
my $sq3 = _which('sqlite3');
SKIP: {
    skip "sqlite3 not on PATH; cannot verify external CLI interop", 4
        unless defined $sq3;

    my ($t_out, $t_err, $t_rc) = capture {
        system($sq3, $arc_path, '.tables');
    };
    is($t_rc, 0, 'sqlite3 .tables exit 0');
    like($t_out, qr/\barchives\b/, "sqlite3 .tables lists 'archives'");

    my ($c_out, $c_err, $c_rc) = capture {
        system($sq3, $arc_path, 'SELECT count(*) FROM archives');
    };
    is($c_rc, 0, 'sqlite3 SELECT count exit 0');

    my ($cnt_line) = $c_out =~ /(\d+)/;
    is($cnt_line, 1, 'sqlite3 SELECT count(*) returns 1');

    # PRAGMA integrity_check: best-effort. If sqlite3 reads the body
    # as page_count*page_size and ignores trailing bytes, this returns
    # 'ok'. Any other outcome is a soft warning -- the previous
    # assertions already prove the trailer doesn't break query usage.
    my ($i_out, $i_err, $i_rc) = capture {
        system($sq3, $arc_path, 'PRAGMA integrity_check;');
    };
    if ($i_rc == 0 && $i_out =~ /^ok\b/m) {
        note 'sqlite3 PRAGMA integrity_check: ok';
    }
    else {
        chomp(my $detail = $i_out . $i_err);
        diag "sqlite3 PRAGMA integrity_check non-ok (rc=$i_rc): $detail";
    }
}
# }}}

# {{{ yath's own reader still works on the trailer-bearing archive.
my $log = App::Yath2::Log->new(file => $arc_path);
isa_ok($log, ['App::Yath2::Log::DB::Sqlite']);

my @runs = $log->runs;
ok(scalar(@runs) >= 1, 'Sqlite->runs returns at least one run');
# }}}

done_testing;
