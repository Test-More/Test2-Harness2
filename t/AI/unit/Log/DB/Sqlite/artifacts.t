use Test2::V0;
use Test2::Require::Module 'DBD::SQLite';

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;

use lib 't/lib';
use Test2::Harness2::Test::DBVersions qw/for_each_log_db_backend/;

use Test2::Harness2::Util::JSON qw/encode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer compress_blob/;
use App::Yath2::Log;

my $src = tempdir(CLEANUP => 1);
make_path("$src/services/harness");
make_path("$src/services/harness/attachments");
make_path("$src/services/preload-perl");
make_path("$src/runs/0/services/run");
make_path("$src/runs/0/jobs/0/0");
make_path("$src/runs/0/jobs/0/1");
make_path("$src/runs/0/jobs/1/0");

# Spec / events / report for the harness service.
my $w_spec = open_zstd_writer("$src/services/harness/spec.jsonl.zst");
$w_spec->say(encode_json({type => 'Service', id => 'harness'}));
$w_spec->close;

my $w_evt = open_zstd_writer("$src/services/harness/events.jsonl.zst");
$w_evt->say(encode_json({facet_data => {harness => {note => 'first'}}}));
$w_evt->say(encode_json({facet_data => {harness => {note => 'second'}}}));
$w_evt->close;

my $w_rep = open_zstd_writer("$src/services/harness/report.jsonl.zst");
$w_rep->say(encode_json({exit => 0}));
$w_rep->close;

# Plain attachment + compressed attachment.
open(my $a1, '>', "$src/services/harness/attachments/0001-hello.txt") or die $!;
print $a1 "hi there\n";
close $a1;

my $compressed_payload = compress_blob("compressed body\n");
open(my $a2, '>', "$src/services/harness/attachments/0002-blob.bin.zst") or die $!;
binmode $a2;
print $a2 $compressed_payload;
close $a2;

for my $base (
    "services/preload-perl",
    "runs/0",
    "runs/0/services/run",
    "runs/0/jobs/0/0",
    "runs/0/jobs/0/1",
    "runs/0/jobs/1/0",
) {
    my $w = open_zstd_writer("$src/$base/events.jsonl.zst");
    $w->say(encode_json({ping => 1}));
    $w->close;
}

# spec.jsonl for each job try -- required now that jobs.test_file_id is NOT NULL.
{
    my $w = open_zstd_writer("$src/runs/0/jobs/0/0/spec.jsonl.zst");
    $w->say(encode_json({relative => 't/job0.t'}));
    $w->close;
}
{
    my $w = open_zstd_writer("$src/runs/0/jobs/0/1/spec.jsonl.zst");
    $w->say(encode_json({relative => 't/job0.t'}));
    $w->close;
}
{
    my $w = open_zstd_writer("$src/runs/0/jobs/1/0/spec.jsonl.zst");
    $w->say(encode_json({relative => 't/job1.t'}));
    $w->close;
}

# Archive once; per backend reopen the SAME archive via the file=>
# shorthand with backend => $name. The high-level Log->new(file=>) is
# what production users hit; this exercises both backends through
# that exact entry point. archive() seeds a clean source-of-truth
# arc_path per iteration so saves done in one iteration cannot bleed
# into the next.
for_each_log_db_backend(sub {
    my $backend = shift;

    my $arc_dir  = tempdir(CLEANUP => 1);
    my $arc_path = "$arc_dir/run.yath";
    App::Yath2::Log->new(dir => $src)->archive($arc_path, format => 'sqlite');

    my $log = App::Yath2::Log->new(file => $arc_path, backend => $backend);
    isa_ok($log, ['App::Yath2::Log::DB']);

    # artifacts() positional/hashref forms.
    {
        my $a = $log->artifacts();
        isa_ok($a, ['App::Yath2::Log::Artifact']);
        is($a->base, undef, 'no base');
    }
    {
        my $a = $log->artifacts('harness');
        is($a->base, 'services/harness', 'global service base');
    }
    {
        my $a = $log->artifacts(0);
        is($a->base, 'runs/0', 'run base');
    }
    {
        my $a = $log->artifacts(0, 'run');
        is($a->base, 'runs/0/services/run', 'run-scoped service base');
    }
    {
        my $a = $log->artifacts(0, 0);
        is($a->base, 'runs/0/jobs/0/1', 'highest try by default');
    }
    {
        my $a = $log->artifacts(0, 0, 0);
        is($a->base, 'runs/0/jobs/0/0', 'specific try');
    }
    {
        my $a = $log->artifacts({service => 'preload-perl'});
        is($a->base, 'services/preload-perl', 'hashref service');

        my $b = $log->artifacts({run_id => 0, job_id => 0, job_try => 1});
        is($b->base, 'runs/0/jobs/0/1', 'hashref triple');
    }

    # Throws on missing target.
    like(dies { $log->artifacts(99) }, qr/no such run/, 'missing run croaks');
    like(dies { $log->artifacts({service => 'nope'}) }, qr/no such service/, 'missing service croaks');
    like(dies { $log->artifacts(0, 99) }, qr/no such job/, 'missing job croaks');
    like(dies { $log->artifacts(0, 0, 99) }, qr/no such try/, 'missing try croaks');

    # events / spec / report bytes are valid plaintext jsonl.
    my $h = $log->artifacts('harness');

    like($h->events, qr/"first"/, 'events bytes contain first');
    like($h->spec,   qr/"harness"/, 'spec bytes contain harness');
    like($h->report, qr/"exit":0/, 'report bytes contain exit:0');

    # events_iter
    {
        my $it = $h->events_iter;
        is($it->count, 2, '2 event rows via iter');
        $it->reset;
        is($it->first->{facet_data}{harness}{note}, 'first', 'first event');
        is($it->last->{facet_data}{harness}{note},  'second', 'last event');
    }

    # attachments listing strips .zst suffix.
    is([$h->attachments], ['0001-hello.txt', '0002-blob.bin'], 'attachments list');

    # attachment plain.
    is($h->attachment('0001-hello.txt'), "hi there\n", 'plain attachment uncompressed');

    # attachment zstd: default uncompressed, compressed=>1 returns raw.
    is($h->attachment('0002-blob.bin'), "compressed body\n", 'zst attachment uncompressed by default');
    is($h->attachment('0002-blob.bin', compressed => 1), $compressed_payload, 'zst attachment raw compressed bytes');

    # filehandle option.
    {
        my $fh = $h->attachment('0001-hello.txt', filehandle => 1);
        ok($fh, 'got a filehandle');
        my $bytes = do { local $/; <$fh> };
        close $fh;
        is($bytes, "hi there\n", 'filehandle reads back contents');
    }

    # exists / get
    ok($h->exists('attachments/0001-hello.txt'), 'exists for arbitrary file');
    ok(!$h->exists('attachments/nope.txt'),      '!exists for missing');
    is($h->get('attachments/0001-hello.txt'), "hi there\n", 'get reads arbitrary file');

    # save IS supported on the SQLite backend (per F23: archive-root
    # arbitrary file save). Use a non-meta.json filename: meta.json reads
    # now reconstruct from archives columns (D9), so a save+get round-trip
    # would be intercepted.
    {
        my $a = $log->artifacts();
        my $ret = $a->save('extras.json', '{"foo":1}');
        ok(defined $ret && length $ret, 'save returns identifier');

        is($a->get('extras.json'), '{"foo":1}', 'get reads back');
        ok($a->exists('extras.json'), 'exists after save');
    }

    # save at job_try scope.
    {
        my $a = $log->artifacts(0, 0, 0);
        $a->save('runtime.json', '{"x":42}');
        is($a->get('runtime.json'), '{"x":42}', 'job-scope save round-trips');
    }

    # save with compress=>1: bytes are stored compressed; reads still
    # decompress by default.
    {
        my $a = $log->artifacts('harness');
        $a->save('extra.txt', "hello\n", compress => 1);
        is($a->get('extra.txt'), "hello\n", 'compressed save reads plaintext by default');
        my $raw = $a->get('extra.txt', compressed => 1);
        isnt($raw, "hello\n", 'compressed=>1 returns compressed bytes');
    }

    # force_no_overwrite throws on existing.
    {
        my $a = $log->artifacts(0, 0, 0);
        $a->save('twice.txt', 'one');
        like(
            dies { $a->save('twice.txt', 'two', force_no_overwrite => 1) },
            qr/already exists/,
            'force_no_overwrite throws',
        );
    }
});

done_testing;
