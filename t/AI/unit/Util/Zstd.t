use strict;
use warnings;

use Test2::V0;
use File::Temp qw/tempdir/;

use Test2::Harness2::Util::Zstd qw{
    compress_blob
    decompress_blob
    compress_file_atomic
    decompress_file
    open_zstd_writer
    open_zstd_reader
};

my $tmp = tempdir(CLEANUP => 1);

# Pull the project's shipped dict so dict-aware tests exercise the
# same bytes the harness uses at runtime. The dict lives at a fixed
# repo-relative path; we resolve it from this test file's location.
use FindBin ();
use File::Spec ();
my $dict_path = File::Spec->catfile(
    $FindBin::Bin, '..', '..', '..', '..', 'share', 'other', 'zstd.dict',
);
unless (-f $dict_path) {
    plan skip_all => "dict not found at $dict_path";
}

# ----------------------------------------------------------------------
# One-shot blob round-trips, dict-less and dict-on.

subtest 'compress_blob / decompress_blob (no dict)' => sub {
    my $payload = qq[{"hello":"world","line":1}\n] x 50;
    my $frame   = compress_blob($payload);
    ok(length($frame) < length($payload), "frame is smaller than source");
    is(decompress_blob($frame), $payload, "round-trip restores payload");
};

subtest 'compress_blob / decompress_blob (with dict)' => sub {
    my $payload = qq[{"facet_data":{"harness":{"kind":"event","run_id":"abc"}}}\n];
    my $frame   = compress_blob($payload, dict_path => $dict_path);
    is(decompress_blob($frame, dict_path => $dict_path), $payload, "dict round-trip");

    my $no_dict_frame = compress_blob($payload);
    ok(
        length($frame) < length($no_dict_frame),
        "dict frame is smaller than dict-less frame for short jsonl",
    );
};

# ----------------------------------------------------------------------
# Atomic file write / read.

subtest 'compress_file_atomic / decompress_file' => sub {
    my $path    = "$tmp/snapshot.json.zst";
    my $payload = qq[{"snapshot":true,"big":"@{['x' x 5000]}"}];
    compress_file_atomic($path, $payload, dict_path => $dict_path);
    ok(-f $path, "file exists after atomic write");
    is(decompress_file($path, dict_path => $dict_path), $payload, "round-trip");

    # Compressed size should be much smaller than payload.
    ok(-s $path < length($payload) / 2, "compressed file is at least 2x smaller");
};

# ----------------------------------------------------------------------
# Append-safe writer + multi-frame reader, both modes.

subtest 'writer/reader round-trip (no dict)' => sub {
    my $path = "$tmp/events_nodict.jsonl.zst";

    my @lines = map { qq[{"event_id":$_,"kind":"sample"}\n] } 1 .. 100;

    my $w = open_zstd_writer($path);
    $w->print($_) for @lines;
    $w->close;

    my $r = open_zstd_reader($path);
    my @got;
    while (defined(my $line = $r->readline)) {
        push @got, $line;
    }
    is(\@got, \@lines, "all lines round-tripped through writer + reader");
};

subtest 'writer/reader round-trip (with dict)' => sub {
    my $path = "$tmp/events_dict.jsonl.zst";

    my @lines = map { qq[{"facet_data":{"harness":{"kind":"event","run_id":"r-$_","job_id":"j-$_"}}}\n] } 1 .. 100;

    my $w = open_zstd_writer($path, dict_path => $dict_path);
    $w->print($_) for @lines;
    $w->close;

    my $r = open_zstd_reader($path, dict_path => $dict_path);
    my @got;
    while (defined(my $line = $r->readline)) {
        push @got, $line;
    }
    is(\@got, \@lines, "all lines round-tripped through writer + reader (dict)");

    # Verify dict produced a smaller file than dict-less framing of
    # the same lines.
    my $other = "$tmp/events_nodict_compare.jsonl.zst";
    my $w2 = open_zstd_writer($other);
    $w2->print($_) for @lines;
    $w2->close;
    ok(-s $path < -s $other, "dict-mode multi-frame stream is smaller than dict-less for short jsonl");
};

# ----------------------------------------------------------------------
# Tail-style reading: writer keeps appending while reader keeps reading.

subtest 'writer + reader interleaved (no dict)' => sub {
    my $path = "$tmp/tail_nodict.jsonl.zst";

    my $w = open_zstd_writer($path);
    $w->print(qq[{"i":1}\n]);
    $w->print(qq[{"i":2}\n]);

    my $r = open_zstd_reader($path);
    is($r->readline, qq[{"i":1}\n], "first frame visible to reader");
    is($r->readline, qq[{"i":2}\n], "second frame visible to reader");

    $w->print(qq[{"i":3}\n]);
    is($r->readline, qq[{"i":3}\n], "appended frame visible after refill");

    $w->close;
};

subtest 'writer + reader interleaved (with dict)' => sub {
    my $path = "$tmp/tail_dict.jsonl.zst";

    my $w = open_zstd_writer($path, dict_path => $dict_path);
    $w->print(qq[{"facet_data":{"harness":{"kind":"event","i":1}}}\n]);
    $w->print(qq[{"facet_data":{"harness":{"kind":"event","i":2}}}\n]);

    my $r = open_zstd_reader($path, dict_path => $dict_path);
    is(
        $r->readline,
        qq[{"facet_data":{"harness":{"kind":"event","i":1}}}\n],
        "first frame visible",
    );
    is(
        $r->readline,
        qq[{"facet_data":{"harness":{"kind":"event","i":2}}}\n],
        "second frame visible",
    );

    $w->print(qq[{"facet_data":{"harness":{"kind":"event","i":3}}}\n]);
    is(
        $r->readline,
        qq[{"facet_data":{"harness":{"kind":"event","i":3}}}\n],
        "appended frame visible after refill",
    );

    $w->close;
};

# ----------------------------------------------------------------------
# Error: dict mismatch should fail loudly.

subtest 'dict mismatch on decompress' => sub {
    my $payload = qq[{"line":1}\n];
    my $frame   = compress_blob($payload, dict_path => $dict_path);

    like(
        dies { decompress_blob($frame) },
        qr/decompress/i,
        "dict-encoded frame fails plain decompress",
    );
};

done_testing;
