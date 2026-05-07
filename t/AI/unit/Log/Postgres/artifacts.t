use Test2::V0;
use Test2::Require::Module 'DBD::Pg';
use Test2::Require::Module 'DBIx::QuickDB';
use Test2::Require::Module 'Test2::Tools::QuickDB';

use Test2::Tools::QuickDB;
skipall_unless_can_db(driver => 'PostgreSQL');

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use DBI ();

use Test2::Harness2::Util::JSON qw/encode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer compress_blob/;
use App::Yath2::Log;
use App::Yath2::Log::Postgres;

my $qdb = get_db({ driver => 'PostgreSQL' });
{
    my $admin = DBI->connect(
        $qdb->connect_string('postgres'), undef, undef,
        { RaiseError => 1, PrintError => 0, AutoCommit => 1, pg_enable_utf8 => 1 },
    ) or die "connect: $DBI::errstr";
    $admin->do('CREATE DATABASE yath_log_test_arts');
    $admin->disconnect;
}
my $dsn = $qdb->connect_string('yath_log_test_arts');

my $src = tempdir(CLEANUP => 1);
make_path("$src/services/harness");
make_path("$src/services/harness/attachments");
make_path("$src/services/preload-perl");
make_path("$src/runs/0/services/run");
make_path("$src/runs/0/jobs/0/0");
make_path("$src/runs/0/jobs/0/1");
make_path("$src/runs/0/jobs/1/0");

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

App::Yath2::Log::Postgres->new(dsn => $dsn)->insert(App::Yath2::Log->new(dir => $src));

my $log = App::Yath2::Log::Postgres->new(dsn => $dsn);
isa_ok($log, ['App::Yath2::Log::Postgres']);

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

like(dies { $log->artifacts(99) }, qr/no such run/, 'missing run croaks');
like(dies { $log->artifacts({service => 'nope'}) }, qr/no such service/, 'missing service croaks');
like(dies { $log->artifacts(0, 99) }, qr/no such job/, 'missing job croaks');
like(dies { $log->artifacts(0, 0, 99) }, qr/no such try/, 'missing try croaks');

my $h = $log->artifacts('harness');

like($h->events, qr/"first"/, 'events bytes contain first');
like($h->spec,   qr/"harness"/, 'spec bytes contain harness');
like($h->report, qr/"exit":0/, 'report bytes contain exit:0');

{
    my $it = $h->events_iter;
    is($it->count, 2, '2 event rows via iter');
    $it->reset;
    is($it->first->{facet_data}{harness}{note}, 'first', 'first event');
    is($it->last->{facet_data}{harness}{note},  'second', 'last event');
}

is([$h->attachments], ['0001-hello.txt', '0002-blob.bin'], 'attachments list');

is($h->attachment('0001-hello.txt'), "hi there\n", 'plain attachment uncompressed');

is($h->attachment('0002-blob.bin'), "compressed body\n", 'zst attachment uncompressed by default');
is($h->attachment('0002-blob.bin', compressed => 1), $compressed_payload, 'zst attachment raw compressed bytes');

{
    my $fh = $h->attachment('0001-hello.txt', filehandle => 1);
    ok($fh, 'got a filehandle');
    my $bytes = do { local $/; <$fh> };
    close $fh;
    is($bytes, "hi there\n", 'filehandle reads back contents');
}

ok($h->exists('attachments/0001-hello.txt'), 'exists for arbitrary file');
ok(!$h->exists('attachments/nope.txt'),      '!exists for missing');
is($h->get('attachments/0001-hello.txt'), "hi there\n", 'get reads arbitrary file');

# save IS supported on the Postgres backend. Use a non-meta.json
# filename: meta.json reads now reconstruct from archives columns
# (D9), so a save+get round-trip would be intercepted.
{
    my $a = $log->artifacts();
    my $ret = $a->save('extras.json', '{"foo":1}');
    ok(defined $ret && length $ret, 'save returns identifier');

    is($a->get('extras.json'), '{"foo":1}', 'get reads back');
    ok($a->exists('extras.json'), 'exists after save');
}

{
    my $a = $log->artifacts(0, 0, 0);
    $a->save('runtime.json', '{"x":42}');
    is($a->get('runtime.json'), '{"x":42}', 'job-scope save round-trips');
}

# Postgres's _payload_compressed_default = 0 means compress=>1 still
# stores raw (server-side TOAST LZ4 handles it). The compressed=>1
# read still works (matches Directory's "one path per file" path
# semantics).
{
    my $a = $log->artifacts('harness');
    $a->save('extra.txt', "hello\n", compress => 1);
    is($a->get('extra.txt'), "hello\n", 'compressed save reads plaintext by default');
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

# Binary round-trip for BYTEA: PNG magic bytes survive.
{
    my $a = $log->artifacts(0, 0, 0);
    my $png_bytes = "\x89PNG\r\n\x1A\nfake-png-data";
    $a->save('shot.png', $png_bytes);
    is($a->get('shot.png'), $png_bytes, 'binary BYTEA round-trip verbatim');
}

done_testing;
