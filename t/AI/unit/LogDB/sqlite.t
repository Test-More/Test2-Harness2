use Test2::V0;
use Test2::Require::Module 'DBD::SQLite';

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;

use Test2::Harness2::Util::JSON qw/encode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
use App::Yath2::Log;
use App::Yath2::Log::DB::Sqlite;
use App::Yath2::LogDB;

# Build three small directory logs and insert them as three archives
# into a single SQLite .yath file. Then open the file as a LogDB and
# verify the multi-archive listing / per-archive log() shapes.

sub build_dir {
    my ($root) = @_;
    make_path("$root/services/harness");
    make_path("$root/runs/0");
    my $w = open_zstd_writer("$root/services/harness/spec.jsonl.zst");
    $w->say(encode_json({type => 'Service', id => 'harness'}));
    $w->close;
    my $w2 = open_zstd_writer("$root/services/harness/events.jsonl.zst");
    $w2->say(encode_json({facet_data => {harness => {note => 'hello'}}}));
    $w2->close;
    my $w3 = open_zstd_writer("$root/runs/0/events.jsonl.zst");
    $w3->say(encode_json({facet_data => {harness => {note => 'run-events'}}}));
    $w3->close;
}

my $tmp = tempdir(CLEANUP => 1);
my $dir1 = "$tmp/log1"; build_dir($dir1);
my $dir2 = "$tmp/log2"; build_dir($dir2);
my $dir3 = "$tmp/log3"; build_dir($dir3);

my $db_path = "$tmp/multi.yath";

# Build the multi-archive SQLite by inserting each source.
my @inserted_uuids;
{
    my $writer = App::Yath2::Log::DB::Sqlite->new(file => $db_path);
    for my $d ($dir1, $dir2, $dir3) {
        my $src = App::Yath2::Log->new(dir => $d);
        $writer->insert($src);
        push @inserted_uuids => $writer->uuid;
    }
}
is(scalar @inserted_uuids, 3, 'three archives inserted');

# Open as LogDB and verify the multi-archive shape.
{
    my $ldb = App::Yath2::LogDB->new(file => $db_path);
    isa_ok($ldb, ['App::Yath2::LogDB']);

    is($ldb->flavor, 'sqlite', 'flavor sqlite');
    is($ldb->archive_count, 3, 'archive_count = 3');

    my @uuids = $ldb->archives;
    is(scalar @uuids, 3, 'three uuids returned');

    # has_archive
    ok($ldb->has_archive($uuids[0]), 'has_archive on present uuid');
    ok($ldb->has_archive(uc $uuids[0]), 'has_archive case-insensitive');
    ok(!$ldb->has_archive('00000000-0000-0000-0000-000000000000'),
        '!has_archive for absent uuid');

    # log($uuid) returns a working Log object scoped to that archive.
    for my $u (@uuids) {
        my $log = $ldb->log($u);
        isa_ok($log, ['App::Yath2::Log::DB::Sqlite']);
        is($log->uuid, $u, 'log uuid matches');

        # Each archive contains the harness service + 1 run.
        my @runs    = $log->runs;
        my @globals = $log->services;
        is(\@runs, [0], 'one run per archive');
        ok(scalar(@globals) >= 1, 'at least one global service');

        # Read events.
        my $a = $log->artifacts('harness');
        like($a->events, qr/hello/, 'harness events readable per-archive');
    }

    # Shared dbh: dbh() returns the same handle each time.
    my $h1 = $ldb->dbh;
    my $h2 = $ldb->dbh;
    ok($h1, 'dbh returns a handle');
    is("$h1", "$h2", 'dbh is stable');
}

# dbh-form constructor.
{
    require DBI;
    my $dbh = DBI->connect("dbi:SQLite:dbname=$db_path", undef, undef, {
        RaiseError => 1, PrintError => 0, AutoCommit => 1,
        sqlite_unicode => 1,
    });
    my $ldb = App::Yath2::LogDB->new(dbh => $dbh);
    is($ldb->flavor, 'sqlite', 'dbh form: flavor');
    is($ldb->archive_count, 3, 'dbh form: archive_count');
}

# A fresh empty file is allowed; archive_count == 0 and log() throws
# on a uuid that does not exist.
{
    my $empty_dir = tempdir(CLEANUP => 1);
    my $empty_db  = "$empty_dir/empty.yath";
    my $ldb = App::Yath2::LogDB->new(file => $empty_db);
    is($ldb->archive_count, 0, 'empty DB: 0 archives');

    like(
        dies { $ldb->log('00000000-0000-0000-0000-000000000000') },
        qr/no such archive/,
        'log() on absent uuid throws',
    );

    like(dies { $ldb->log() }, qr/uuid/, 'log() without uuid throws');
}

# Construction validation.
like(
    dies { App::Yath2::LogDB->new() },
    qr/requires one of/,
    'no args -> error',
);

# Non-sqlite file path -> rejected.
{
    my $d = tempdir(CLEANUP => 1);
    my $bogus = "$d/bogus.bin";
    open(my $fh, '>', $bogus) or die $!;
    print $fh "not a sqlite file";
    close $fh;
    like(
        dies { App::Yath2::LogDB->new(file => $bogus) },
        qr/not a SQLite database/,
        'non-sqlite file rejected',
    );
}

done_testing;
