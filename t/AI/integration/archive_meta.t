use Test2::V0;
use Test2::Require::Module 'DBD::SQLite';

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;

use Test2::Harness2::Util::JSON qw/encode_json decode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
use App::Yath2::Log;

# Build a small directory log, archive it under tar.zidx and sqlite
# shapes, and verify meta.json lands at the archive root with the
# expected fields. Also verify extracting back to a directory
# preserves meta.json. Live dirs do NOT get a meta.json.

sub build_dir {
    my ($root) = @_;
    make_path("$root/services/harness");
    make_path("$root/runs/0");

    my $w = open_zstd_writer("$root/services/harness/spec.jsonl.zst");
    $w->say(encode_json({type => 'Service', id => 'harness'}));
    $w->close;

    my $w2 = open_zstd_writer("$root/services/harness/events.jsonl.zst");
    $w2->say(encode_json({facet_data => {harness => {note => 'hi'}}}));
    $w2->close;

    my $w3 = open_zstd_writer("$root/runs/0/events.jsonl.zst");
    $w3->say(encode_json({facet_data => {harness => {note => 'r0'}}}));
    $w3->close;
}

my $tmp = tempdir(CLEANUP => 1);
my $src = "$tmp/src";
build_dir($src);

# A live directory must not have meta.json (sealed-only artifact).
{
    my $live = "$tmp/live";
    build_dir($live);
    open(my $fh, '>', "$live/LIVE") or die $!;
    print $fh "1\n";
    close $fh;
    my $log = App::Yath2::Log->new(live => $live);
    my $a = $log->artifacts;
    ok(!$a->exists('meta.json'), 'live dir does NOT carry meta.json');
}

# {{{ tar.zidx round-trip
{
    my $tar = "$tmp/run.yath";
    App::Yath2::Log->new(dir => $src)->archive($tar);

    my $log = App::Yath2::Log->new(file => $tar);
    my $a = $log->artifacts;
    ok($a->exists('meta.json'), 'tar.zidx: meta.json present at archive root');

    my $bytes = $a->get('meta.json');
    my $meta = decode_json($bytes);
    is($meta->{format_version}, 1, 'tar.zidx meta: format_version 1');
    like($meta->{archive_uuid}, qr/^[0-9A-Fa-f-]{36}$/, 'tar.zidx meta: archive_uuid shape');
    like($meta->{created_at},   qr/^\d{4}-\d{2}-\d{2}T/, 'tar.zidx meta: ISO timestamp');
    ok(defined $meta->{host},        'tar.zidx meta: host set');
    ok(defined $meta->{user},        'tar.zidx meta: user set');
    ok(defined $meta->{yath_version},'tar.zidx meta: yath_version set');
    ok(exists $meta->{git_sha}, 'tar.zidx meta: git_sha key present');
    ok(exists $meta->{project},'tar.zidx meta: project key present');

    # Extract back to a directory; meta.json should land at the root.
    my $extract_dir = "$tmp/extracted";
    $log->extract($extract_dir);
    ok(-e "$extract_dir/meta.json" || -e "$extract_dir/meta.json.zst",
        'tar.zidx extract: meta.json present at extracted root');
}
# }}}

# {{{ sqlite round-trip
{
    my $sq = "$tmp/run.sqlite.yath";
    App::Yath2::Log->new(dir => $src)->archive($sq, format => 'sqlite');

    my $log = App::Yath2::Log->new(file => $sq);
    my $a = $log->artifacts;
    ok($a->exists('meta.json'), 'sqlite: meta.json present');
    my $meta = decode_json($a->get('meta.json'));
    is($meta->{format_version}, 1, 'sqlite meta: format_version 1');
    like($meta->{archive_uuid}, qr/^[0-9A-Fa-f-]{36}$/, 'sqlite meta: archive_uuid shape');
    is($meta->{archive_uuid}, $log->uuid, 'sqlite meta archive_uuid matches archives row');

    # Extract sqlite to dir and verify meta lands too.
    my $extract = "$tmp/sql-extracted";
    $log->extract($extract);
    ok(-e "$extract/meta.json" || -e "$extract/meta.json.zst",
        'sqlite extract: meta.json present at extracted root');
}
# }}}

# {{{ insert() into multi-archive DB drops a fresh meta.json per archive
{
    require App::Yath2::Log::Sqlite;
    my $db_path = "$tmp/multi.yath";
    my $writer = App::Yath2::Log::Sqlite->new(file => $db_path);

    my @uuids;
    for (1 .. 3) {
        my $src_log = App::Yath2::Log->new(dir => $src);
        $writer->insert($src_log);
        push @uuids => $writer->uuid;
    }

    is(scalar @uuids, 3, 'three archives inserted');
    is(scalar(do { my %s; @s{@uuids} = (); keys %s }), 3, 'each archive has a unique uuid');

    require App::Yath2::LogDB;
    my $ldb = App::Yath2::LogDB->new(file => $db_path);
    is($ldb->archive_count, 3, 'LogDB: 3 archives');

    for my $u (@uuids) {
        my $log = $ldb->log($u);
        my $a = $log->artifacts;
        ok($a->exists('meta.json'), "archive $u has meta.json");
        my $meta = decode_json($a->get('meta.json'));
        is($meta->{archive_uuid}, $u, "archive $u meta.json archive_uuid matches");
    }
}
# }}}

done_testing;
