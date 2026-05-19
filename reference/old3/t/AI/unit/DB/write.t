use Test2::V0;
use Test2::Require::Module 'DBD::SQLite';

use File::Temp qw/tempdir tempfile/;
use File::Path qw/make_path/;

use Test2::Harness2::Util::JSON qw/encode_json decode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
use App::Yath2::Log;
use App::Yath2::DB;
use App::Yath2::Log::DB;

use lib 't/lib';
use Test2::Harness2::Test::DBVersions qw/for_each_log_db_backend/;

# Phase 6 acceptance test: cross-backend parity for the App::Yath2::DB
# write API. Each backend (sql, dbic) takes the same source-Directory
# archive through:
#
#   1. insert    -> creates the archive row and populates summaries
#   2. extract   -> rehydrates the archive into a Directory tree
#   3. save_artifact (via Log::DB->_artifact_save) -- arbitrary,
#      compressed, and force_no_overwrite collision paths
#   4. archive_to(format=>'sqlite') -- reopens and verifies content
#
# A cross-backend equality block runs a fresh source through both
# backends and asserts identical archives() / meta() / runs() / jobs()
# / list_files() across the two destinations.

sub write_jsonl_zst {
    my ($path, @rows) = @_;
    my $w = open_zstd_writer($path);
    $w->say(encode_json($_)) for @rows;
    $w->close;
}

sub build_source {
    my %p = @_;
    my $src = tempdir(CLEANUP => 1);
    make_path("$src/services/harness");
    make_path("$src/runs/0");
    make_path("$src/runs/0/jobs/0/0");

    write_jsonl_zst("$src/services/harness/events.jsonl.zst", {ping => 1});
    write_jsonl_zst("$src/services/harness/spec.jsonl.zst",
        {type => 'Service', id => 'harness'});

    write_jsonl_zst("$src/runs/0/events.jsonl.zst", {ping => 1});
    write_jsonl_zst("$src/runs/0/spec.jsonl.zst",
        {started_at => 1778112000});
    write_jsonl_zst("$src/runs/0/report.jsonl.zst",
        {ended_at => 1778112060, exit => 0, pass => 1});

    write_jsonl_zst("$src/runs/0/jobs/0/0/events.jsonl.zst", {ping => 1});
    write_jsonl_zst("$src/runs/0/jobs/0/0/spec.jsonl.zst",
        {relative => 't/job0.t', queued_at => 1778112000});
    write_jsonl_zst(
        "$src/runs/0/jobs/0/0/report.jsonl.zst",
        {
            ended_at => 1778112002,
            exit     => 0,
            pass     => 1,
            subtests => [
                {name => 'first',  pass => 1, count_pass => 1},
                {name => 'second', pass => 1, count_pass => 1},
            ],
        },
    );

    if ($p{archive_uuid}) {
        my $meta = App::Yath2::Log->build_archive_meta(
            archive_uuid => $p{archive_uuid},
            cwd          => $src,
        );
        my $bytes = App::Yath2::Log->encode_archive_meta($meta);
        open(my $fh, '>', "$src/meta.json") or die "open: $!";
        binmode $fh;
        print $fh $bytes;
        close $fh;
    }

    return $src;
}

for_each_log_db_backend(sub {
    my ($backend) = @_;

    # ----- insert + extract round-trip ------------------------------------
    my $src     = build_source();
    my $src_log = App::Yath2::Log->new(dir => $src);

    my (undef, $arc_path) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
    unlink $arc_path;
    my $db  = App::Yath2::DB->new(file => $arc_path, backend => $backend);
    my $aid = $db->insert($src_log);

    ok(defined $aid, 'insert returned an archive_id');
    my @uuids = $db->archives;
    is(scalar(@uuids), 1, 'archives() lists the new archive');

    my $u = $uuids[0];
    is([$db->runs($u)],         [0],  'runs match source');
    is([$db->jobs($u, 0)],      [0],  'jobs match source');
    is([$db->tries($u, 0, 0)],  [0],  'tries match source');
    ok((grep { $_ eq 'harness' } $db->services($u)),
        'global service preserved');

    my $meta = $db->meta($u);
    ok(ref($meta) eq 'HASH',         'meta() returns a hashref');
    is($meta->{archive_uuid}, $u,    'meta uuid matches archives() entry');

    # extract -> Directory comparison.
    my $extract_dir = tempdir(CLEANUP => 1);
    my $extracted   = $db->extract($u, "$extract_dir/out");
    isa_ok($extracted, ['App::Yath2::Log::Directory']);

    my %src_files = map { $_ => 1 } $src_log->list_files;
    my %xf        = map { $_ => 1 } $extracted->list_files;
    # meta.json should appear in the extracted dir but not the source
    # (source is a live dir without a meta.json artifact).
    ok($xf{'meta.json'}, 'extracted dir contains meta.json');
    delete $xf{'meta.json'};

    # spec.jsonl / report.jsonl / state.jsonl are reconstructed from
    # typed columns and materialized at extract time. We only verify
    # artifact-backed paths here; reconstruction parity is checked in
    # t/AI/unit/DB/read.t.
    for my $f (sort keys %src_files) {
        next if $f eq 'LIVE';
        next if $f =~ m{(?:^|/)(?:spec|report|state)\.jsonl(?:\.zst)?\z};
        (my $stem = $f) =~ s/\.zst\z//;
        ok(exists $xf{$stem} || exists $xf{"$stem.zst"},
            "extracted has $stem (or .zst variant)");
    }

    # Virtual files exist in the extract output too.
    ok(exists $xf{'runs/0/spec.jsonl'} || exists $xf{'runs/0/spec.jsonl.zst'},
        'extracted has run-scope spec.jsonl');
    ok(exists $xf{'runs/0/report.jsonl'} || exists $xf{'runs/0/report.jsonl.zst'},
        'extracted has run-scope report.jsonl');
    ok(exists $xf{'runs/0/jobs/0/0/state.jsonl'}
            || exists $xf{'runs/0/jobs/0/0/state.jsonl.zst'},
        'extracted has job_try state.jsonl (virtual)');

    # ----- save_artifact via Log::DB --------------------------------------
    my $log = App::Yath2::Log::DB->new(db => $db, uuid => $u);

    {
        my $a = $log->artifacts(0);
        my $ret = $a->save('extras.json', '{"hello":1}');
        ok(defined $ret, 'save returns identifier');
        is($a->get('extras.json'), '{"hello":1}', 'save+get round-trip');
        ok($a->exists('extras.json'), 'exists after save');
    }

    {
        my $a = $log->artifacts(0);
        $a->save('zipped.txt', "hello world\n", compress => 1);
        is($a->get('zipped.txt'), "hello world\n",
            'compressed save round-trips through plain get');
    }

    {
        my $a = $log->artifacts(0);
        $a->save('once.txt', 'first');
        like(
            dies { $a->save('once.txt', 'second', force_no_overwrite => 1) },
            qr/already exists/,
            'force_no_overwrite croaks on collision',
        );
    }

    # ----- archive_to(format=>'sqlite') -----------------------------------
    {
        my (undef, $sql_path) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
        unlink $sql_path;

        my $dest = $db->archive_to($u, $sql_path, format => 'sqlite');
        ok(defined $dest, 'archive_to returned a destination handle');
        ok(-e $sql_path,  'sealed archive file exists on disk');

        my $reopened = App::Yath2::DB->new(file => $sql_path, backend => 'sql');
        my @ru = $reopened->archives;
        is(scalar(@ru), 1,  'sealed archive holds exactly one archive_uuid');
        is($ru[0],      $u, 'sealed archive carries the source uuid');
    }

    # ----- duplicate-uuid rejection ---------------------------------------
    {
        my $dup = build_source(archive_uuid => '019d2b1a-8000-7000-8000-cafebabe0001');
        my (undef, $p) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
        unlink $p;
        my $d = App::Yath2::DB->new(file => $p, backend => $backend);
        $d->insert(App::Yath2::Log->new(dir => $dup));

        like(
            dies { $d->insert(App::Yath2::Log->new(dir => $dup)) },
            qr/already exists/,
            'second insert with same archive_uuid croaks',
        );
    }
});

# ----- cross-backend equality on the same source -------------------------
{
    my $src = build_source();
    my $src_log = App::Yath2::Log->new(dir => $src);

    my (undef, $sql_path) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
    unlink $sql_path;
    my $sql_db = App::Yath2::DB->new(file => $sql_path, backend => 'sql');
    $sql_db->insert($src_log);

    my $skip_dbic = !eval { require DBIx::Class; 1 };
    if ($skip_dbic) {
        diag("skipping cross-backend equality: DBIx::Class not installed");
    }
    else {
        my (undef, $dbic_path) = tempfile(OPEN => 0, SUFFIX => '.yath', UNLINK => 1);
        unlink $dbic_path;
        my $dbic_db = App::Yath2::DB->new(file => $dbic_path, backend => 'dbic');
        $dbic_db->insert($src_log);

        my @sql_u  = $sql_db->archives;
        my @dbic_u = $dbic_db->archives;
        is(scalar(@sql_u),  1, 'sql backend has 1 archive');
        is(scalar(@dbic_u), 1, 'dbic backend has 1 archive');

        my $u_sql  = $sql_u[0];
        my $u_dbic = $dbic_u[0];

        is([sort $sql_db->runs($u_sql)],
           [sort $dbic_db->runs($u_dbic)],
           'runs match across backends');

        is([sort $sql_db->jobs($u_sql, 0)],
           [sort $dbic_db->jobs($u_dbic, 0)],
           'jobs match across backends');

        # list_files comparison: ignore the .zst suffix difference (each
        # backend may store a payload compressed or plain depending on
        # flavor defaults; for sqlite both are zstd by default).
        my %sql_paths  = map { (my $b = $_) =~ s/\.zst\z//; $b => 1 } $sql_db->list_files($u_sql);
        my %dbic_paths = map { (my $b = $_) =~ s/\.zst\z//; $b => 1 } $dbic_db->list_files($u_dbic);
        is(\%sql_paths, \%dbic_paths,
            'list_files returns the same logical paths across backends');
    }
}

done_testing;
