use Test2::V0;

# Unit test for the DB logger's binary-extraction path (#50 / spec §5):
# while storing a collector's events.jsonl.zst as an artifact blob, any event
# carrying an embedded `binary` facet has that binary split into its OWN binary
# artifact row (artifact_uuid = derive(collector_uuid, idx>=1)) and the event's
# facet is rewritten to reference the new artifact_uuid (bytes removed, event
# retained). Events with no binary leave the on-disk blob canonical (verbatim).
#
# Drives App::Yath2::DB::Logger::_read_and_extract directly against a synthetic
# events file (one frame per record, the recorder's format) so the extraction is
# tested without spinning up a runner. Skipped cleanly if Compress::Zstd is absent.

use Test2::Collector::Util::Zstd qw/HAVE_ZSTD compress_blob open_zstd_reader/;
use Test2::Collector::Util::JSON qw/decode_json/;

skip_all "Compress::Zstd not available" unless HAVE_ZSTD;

use MIME::Base64 qw/encode_base64/;
use File::Temp qw/tempfile/;

use App::Yath2::DB::Logger;
use App::Yath2::Util::UUID qw/gen_uuid derive_uuid/;

# Build a synthetic events.jsonl.zst: one plain event, one event with a binary
# facet (an image), one more plain event. Each record = its own zstd frame.
sub write_events_file {
    my (@records) = @_;
    my ($fh, $path) = tempfile("events-XXXXXX", TMPDIR => 1, SUFFIX => '.jsonl.zst', UNLINK => 1);
    binmode($fh);
    require Test2::Collector::Util::JSON;
    for my $rec (@records) {
        print $fh compress_blob(Test2::Collector::Util::JSON::encode_json($rec) . "\n");
    }
    close($fh);
    return $path;
}

my $collector_uuid = gen_uuid();

my $png_bytes = "\x89PNG\r\n\x1a\n" . ("BINARYIMAGEDATA" x 4);

my @records = (
    {facet_data => {info => [{tag => 'NOTE', details => 'plain event, no binary'}]}},
    {
        facet_data => {
            assert => {pass => 1, details => 'an assertion with an attachment'},
            binary => [
                {
                    filename => 'screenshot.png',
                    details  => 'a screenshot',
                    data     => encode_base64($png_bytes, ''),
                    is_image => 1,
                },
            ],
        },
    },
    {facet_data => {info => [{tag => 'NOTE', details => 'another plain event'}]}},
);

my $events_file = write_events_file(@records);

# Construct a logger without running it; call the extraction directly.
my $logger = App::Yath2::DB::Logger->new(
    workdir => '/tmp',
    run_id  => gen_uuid(),
    target  => '/tmp/unused.sqlite',
);

my $run_uuid = gen_uuid();

my ($blob, $binaries) = $logger->_read_and_extract($events_file, $collector_uuid, $run_uuid);

# ---- the extracted binary artifact -------------------------------------------
is(scalar(@$binaries), 1, "exactly one binary extracted");

my $bin = $binaries->[0];
is($bin->{filename}, 'screenshot.png', "binary artifact carries the filename");
is($bin->{data}, $png_bytes, "binary artifact data is the DECODED bytes (base64 decoded)");

# Deterministic identity: derive(collector_uuid, 1) -- the first binary (index>=1).
is(
    $bin->{artifact_uuid},
    derive_uuid(lc($collector_uuid), 1),
    "binary artifact_uuid = derive(collector_uuid, 1) (v7-preserving, deterministic)",
);

# ---- the rewritten event stream ----------------------------------------------
# Decode the rebuilt blob frame-by-frame and confirm the binary event's facet was
# rewritten: bytes removed, artifact_uuid reference added; the event is retained.
my ($rfh, $rpath) = tempfile("rewritten-XXXXXX", TMPDIR => 1, SUFFIX => '.jsonl.zst', UNLINK => 1);
binmode($rfh);
print $rfh $blob;
close($rfh);

my $reader = open_zstd_reader($rpath);
my @decoded;
while (defined(my $line = $reader->readline)) {
    push @decoded => decode_json($line);
}

is(scalar(@decoded), 3, "all three events retained in the rewritten stream");

my $bin_event = $decoded[1];
my $facet      = $bin_event->{facet_data}{binary}[0];
ok(!exists($facet->{data}), "binary bytes removed from the rewritten event facet");
is($facet->{artifact_uuid}, $bin->{artifact_uuid}, "event facet rewritten to reference the binary artifact_uuid");
ok($facet->{extracted}, "event facet flagged as extracted");
is($facet->{filename}, 'screenshot.png', "event facet keeps its filename");

# The plain events round-trip unchanged.
is($decoded[0]{facet_data}{info}[0]{details}, 'plain event, no binary', "first plain event intact");
is($decoded[2]{facet_data}{info}[0]{details}, 'another plain event',    "last plain event intact");

# ---- no-binary fast path -----------------------------------------------------
# A file with NO binary facet is stored verbatim (the on-disk blob is canonical).
my $plain_file = write_events_file(
    {facet_data => {info => [{tag => 'NOTE', details => 'only plain events here'}]}},
);
open(my $raw_fh, '<:raw', $plain_file) or die $!;
my $raw = do { local $/; <$raw_fh> };
close($raw_fh);

my ($plain_blob, $plain_bins) = $logger->_read_and_extract($plain_file, gen_uuid(), $run_uuid);
is(scalar(@$plain_bins), 0, "no binaries extracted from a plain stream");
is($plain_blob, $raw, "a binary-free stream is stored verbatim (canonical on-disk blob)");

done_testing;
