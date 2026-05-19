use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;

use Test2::Harness2::Util::JSON qw/encode_json decode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;

use App::Yath2::Log;
use App::Yath2::Log::Footer qw{
    FOOTER_SIZE
    FORMAT_ID_TAR
    FLAG_META_COMPRESSED
    has_footer
    read_footer_from_path
    read_meta_from_path
};

# {{{ Build a small live-like source directory and seal it.

my $src = tempdir(CLEANUP => 1);
make_path("$src/services/harness");
make_path("$src/runs/0/jobs/0/0");

for my $base ("services/harness", "runs/0", "runs/0/jobs/0/0") {
    my $w = open_zstd_writer("$src/$base/events.jsonl.zst");
    $w->say(encode_json({ping => 1}));
    $w->close;
}

my $arc_dir  = tempdir(CLEANUP => 1);
my $arc_path = "$arc_dir/run.yath";

App::Yath2::Log->new(dir => $src)->archive($arc_path);

ok(-s $arc_path, 'archive non-empty');

# }}}

# {{{ YATHFOOT trailer presence + structure.

ok(has_footer($arc_path), 'archive ends with a YATHFOOT trailer');

my $footer = read_footer_from_path($arc_path);
ok($footer, 'footer parsed');

is($footer->{format_id}, FORMAT_ID_TAR, 'format_id is TAR');
ok($footer->{flags} & FLAG_META_COMPRESSED, 'meta payload is zstd-compressed');
ok($footer->{meta_size}   > 0, 'meta payload is non-empty');
ok($footer->{meta_offset} > 0, 'meta payload offset is past start');
ok($footer->{format_ptr}  > 0, 'format_ptr points somewhere');
ok($footer->{body_size} > $footer->{format_ptr},
    'body_size points past the zidx footer');
ok($footer->{meta_offset} >= $footer->{body_size},
    'meta payload starts after body / zidx footer');

my $size = -s $arc_path;
is($footer->{meta_offset} + $footer->{meta_size},
    $size - FOOTER_SIZE,
    'meta payload sits exactly between body_size and YATHFOOT');

# }}}

# {{{ Round-trip: read meta from trailer + meta member from tar match.

my ($meta_bytes, $info) = read_meta_from_path($arc_path);
ok(length($meta_bytes), 'trailer meta decoded to non-empty bytes');

my $trailer_meta = decode_json($meta_bytes);
ok($trailer_meta->{archive_uuid}, 'trailer meta has archive_uuid');
ok($trailer_meta->{created_at},   'trailer meta has created_at');

# Open via Log dispatcher; should return a TarZIdx and the index
# should be located via YATHFOOT's format_ptr (not "last 32 bytes").
my $log = App::Yath2::Log->new(file => $arc_path);
isa_ok($log, ['App::Yath2::Log::TarZIdx']);

ok($log->has_file('meta.json'), 'meta.json member exists in tar');

my $member_fh = $log->read_file('meta.json');
my $member_bytes = do { local $/; <$member_fh> };
close $member_fh;

my $member_meta = decode_json($member_bytes);
is(
    $member_meta->{archive_uuid},
    $trailer_meta->{archive_uuid},
    'tar meta.json member and YATHFOOT meta carry the same archive_uuid',
);

# Index reachable means listing works.
my @files = $log->list_files;
ok(scalar(@files) >= 1, 'list_files returns entries via YATHFOOT-located index');

# }}}

done_testing;
