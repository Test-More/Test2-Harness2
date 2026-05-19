use Test2::V0;
use Test2::Require::AuthorTesting;

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use File::Spec ();
use Capture::Tiny qw/capture/;

use Test2::Harness2::Util::JSON qw/encode_json decode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;

use App::Yath2::Log;
use App::Yath2::Log::TarZIdx;
use App::Yath2::Log::Footer qw{
    FOOTER_SIZE
    FORMAT_ID_TAR
    FLAG_META_COMPRESSED
    has_footer
    read_footer_from_path
    read_meta_from_path
};

# F4 round-trip integration: build a synthetic Log directory, archive
# it to tar.zidx (sealed with YATHFOOT), and verify both yath's own
# reader and the system `tar` CLI can recover meta.json. The system
# tar block is skipped cleanly when `tar` is not on PATH.

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

# spec.jsonl required for the harness service entry-point check and
# the per-job slot.
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

# Archive the source directory to a tar.zidx-format .yath file. Use a
# path inside a CLEANUP-on-exit tempdir rather than tempfile() so we
# don't race with parallel tests that also pull names from /tmp via
# File::Temp.
my $arc_dir  = tempdir(CLEANUP => 1);
my $arc_path = "$arc_dir/run.yath";

App::Yath2::Log->new(dir => $src)->archive($arc_path);
ok(-s $arc_path, 'archive non-empty');

# {{{ Trailer presence + structure.
ok(has_footer($arc_path), 'archive ends with a YATHFOOT trailer');

my $footer = read_footer_from_path($arc_path);
ok($footer, 'footer parsed');
is($footer->{format_id}, FORMAT_ID_TAR, 'format_id is TAR');
ok($footer->{flags} & FLAG_META_COMPRESSED, 'meta payload is zstd-compressed');
ok($footer->{format_ptr} > 0, 'format_ptr points at zidx footer');
ok($footer->{meta_size}  > 0, 'meta payload non-empty');
# }}}

# {{{ Trailer-extracted meta is well-formed JSON with archive_uuid.
my ($meta_bytes, $f2) = read_meta_from_path($arc_path);
ok(length($meta_bytes), 'trailer meta decoded to non-empty bytes');

my $trailer_meta = decode_json($meta_bytes);
ok($trailer_meta->{archive_uuid}, 'trailer meta has archive_uuid');
ok($trailer_meta->{created_at},   'trailer meta has created_at');
# }}}

# {{{ External `tar` CLI verification.
my $tar_bin = _which('tar');
SKIP: {
    skip "tar not on PATH; cannot verify external tar interop", 5
        unless defined $tar_bin;

    my ($list_out, $list_err, $list_rc) = capture {
        system($tar_bin, '-tf', $arc_path);
    };
    is($list_rc, 0, 'tar -tf exit 0');
    # The yath tar.zidx writer stores meta.json zstd-compressed, so
    # the tar member is named meta.json.zst.
    like($list_out, qr{^meta\.json\.zst$}m,
        'meta.json.zst appears in tar listing');

    my $extract_to = tempdir(CLEANUP => 1);
    my (undef, undef, $ext_rc) = capture {
        system($tar_bin, '-xf', $arc_path, '-C', $extract_to);
    };
    is($ext_rc, 0, 'tar -xf exit 0');

    my $extracted_meta = "$extract_to/meta.json.zst";
    ok(-f $extracted_meta, "tar -xf produced $extracted_meta");

    open(my $fh, '<', $extracted_meta) or die "open extracted meta: $!";
    binmode $fh;
    my $extracted_bytes = do { local $/; <$fh> };
    close $fh;

    require Test2::Harness2::Util::Zstd;
    my $extracted_plain
        = Test2::Harness2::Util::Zstd::decompress_blob($extracted_bytes);
    my $extracted = decode_json($extracted_plain);
    is(
        $extracted->{archive_uuid},
        $trailer_meta->{archive_uuid},
        'tar-extracted meta.json carries the same archive_uuid as the trailer',
    );
}
# }}}

# {{{ yath's own reader still works on the trailer-bearing archive.
my $log = App::Yath2::Log->new(file => $arc_path);
isa_ok($log, ['App::Yath2::Log::TarZIdx']);

my @files = $log->list_files;
ok(scalar(@files) >= 1, 'TarZIdx->list_files returns entries');

ok($log->has_file('meta.json'), 'meta.json member is reachable via the index');
# }}}

done_testing;
