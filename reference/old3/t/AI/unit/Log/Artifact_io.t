use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;

use Test2::Harness2::Util::JSON  qw/encode_json/;
use Test2::Harness2::Util::Zstd  qw/open_zstd_writer compress_blob/;
use App::Yath2::Log;

# Build a tiny synthetic harness artifact directory with the standard
# trio plus an attachment.
my $dir = tempdir(CLEANUP => 1);
make_path("$dir/services/harness");
make_path("$dir/services/harness/attachments");

my $w_spec = open_zstd_writer("$dir/services/harness/spec.jsonl.zst");
$w_spec->say(encode_json({type => 'Service', id => 'harness'}));
$w_spec->close;

my $w_evt = open_zstd_writer("$dir/services/harness/events.jsonl.zst");
$w_evt->say(encode_json({facet_data => {harness => {note => 'first'}}}));
$w_evt->say(encode_json({facet_data => {harness => {note => 'second'}}}));
$w_evt->close;

my $w_rep = open_zstd_writer("$dir/services/harness/report.jsonl.zst");
$w_rep->say(encode_json({exit => 0}));
$w_rep->close;

# Plain attachment (uncompressed).
open(my $a1, '>', "$dir/services/harness/attachments/0001-hello.txt") or die $!;
print $a1 "hi there\n";
close $a1;

# Compressed attachment.
my $compressed_payload = compress_blob("compressed body\n");
open(my $a2, '>', "$dir/services/harness/attachments/0002-blob.bin.zst") or die $!;
binmode $a2;
print $a2 $compressed_payload;
close $a2;

my $log = App::Yath2::Log->new(dir => $dir);
my $a   = $log->artifacts('harness');

# events / spec / report bytes.
like($a->events, qr/"first"/, 'events bytes contain first');
like($a->spec,   qr/"harness"/, 'spec bytes contain harness');
like($a->report, qr/"exit":0/, 'report bytes contain exit:0');

# events_iter
{
    my $it = $a->events_iter;
    is($it->count, 2, '2 event rows');
    $it->reset;
    is($it->first->{facet_data}{harness}{note}, 'first', 'first event');
    is($it->last->{facet_data}{harness}{note},  'second', 'last event');
}

# attachment list
is([$a->attachments], ['0001-hello.txt', '0002-blob.bin'], 'attachments list (suffix stripped)');

# attachment plain (uncompressed by default).
is($a->attachment('0001-hello.txt'), "hi there\n", 'plain attachment uncompressed');

# attachment zstd: default uncompressed, compressed=>1 returns raw.
is($a->attachment('0002-blob.bin'), "compressed body\n", 'zst attachment uncompressed by default');
is($a->attachment('0002-blob.bin', compressed => 1), $compressed_payload, 'zst attachment raw compressed bytes');

# filehandle option.
my $fh = $a->attachment('0001-hello.txt', filehandle => 1);
ok($fh, 'got a filehandle');
my $bytes = do { local $/; <$fh> };
close $fh;
is($bytes, "hi there\n", 'filehandle reads back contents');

# exists / get
ok($a->exists('attachments/0001-hello.txt'), 'exists for arbitrary file');
ok(!$a->exists('attachments/nope.txt'),      '!exists for missing');

is($a->get('attachments/0001-hello.txt'), "hi there\n", 'get reads arbitrary file');

done_testing;
