use Test2::V0;
use File::Temp qw/tempfile/;
use Fcntl qw/SEEK_SET SEEK_END/;

use App::Yath2::Log::Footer qw{
    FOOTER_MAGIC
    FOOTER_TAIL
    FOOTER_SIZE
    FOOTER_VERSION
    FORMAT_ID_TAR
    FORMAT_ID_SQL
    FLAG_META_COMPRESSED
    pack_footer
    unpack_footer
    crc32_of
    append_meta
    read_footer_from_path
    read_meta_from_path
    has_footer
};

use Test2::Harness2::Util::Zstd qw/decompress_blob/;

# {{{ Constants and basic invariants

is(FOOTER_MAGIC,    'YATHFOOT', 'head magic');
is(FOOTER_TAIL,     'YATHTAIL', 'tail magic');
is(FOOTER_SIZE,     64,         'trailer is 64 bytes');
is(FOOTER_VERSION,  1,          'version 1');
is(FORMAT_ID_TAR,   'TAR',      'tar format id');
is(FORMAT_ID_SQL,   'SQL',      'sqlite format id');
is(FLAG_META_COMPRESSED, 0x01,  'compressed flag bit');

# }}}

# {{{ pack_footer / unpack_footer round-trips

subtest 'pack_footer produces exactly 64 bytes' => sub {
    my $bytes = pack_footer(
        format_id   => 'TAR',
        meta_offset => 100,
        meta_size   => 50,
        body_size   => 1024,
    );
    is(length($bytes), FOOTER_SIZE, '64-byte trailer');
};

subtest 'round-trip various format ids' => sub {
    for my $fid ('TAR', 'SQL', "TAR\0", 'X', 'AB', 'ABCD') {
        my $packed = pack_footer(
            format_id   => $fid,
            flags       => 0,
            meta_offset => 0,
            meta_size   => 0,
            meta_crc32  => 0,
            body_size   => 0,
            format_ptr  => 0,
        );
        my $u = unpack_footer($packed);
        ok($u, "unpack succeeds for fid '" . _show($fid) . "'");
        (my $expect = $fid) =~ s/\0+\z//;
        is($u->{format_id}, $expect, "format_id NUL-stripped to '$expect'");
    }
};

subtest 'round-trip preserves all numeric fields' => sub {
    no warnings 'portable';   # 64-bit hex literals exceed 0xFFFFFFFF
    my $packed = pack_footer(
        format_id   => 'TAR',
        flags       => FLAG_META_COMPRESSED,
        meta_offset => 0x0123_4567_89AB_CDEF,
        meta_size   => 0xFEDC_BA98_7654_3210,
        meta_crc32  => 0xDEAD_BEEF,
        body_size   => 0x1122_3344_5566_7788,
        format_ptr  => 0x9988_7766_5544_3322,
    );
    my $u = unpack_footer($packed);
    is($u->{magic},              FOOTER_MAGIC,           'head magic');
    is($u->{trailer_self_magic}, FOOTER_TAIL,            'tail magic');
    is($u->{version},            FOOTER_VERSION,         'version');
    is($u->{flags},              FLAG_META_COMPRESSED,   'flags');
    is($u->{format_id},          'TAR',                  'format_id');
    is($u->{meta_offset},        0x0123_4567_89AB_CDEF,  'meta_offset');
    is($u->{meta_size},          0xFEDC_BA98_7654_3210,  'meta_size');
    is($u->{meta_crc32},         0xDEAD_BEEF,            'meta_crc32');
    is($u->{body_size},          0x1122_3344_5566_7788,  'body_size');
    is($u->{format_ptr},         0x9988_7766_5544_3322,  'format_ptr');
};

# }}}

# {{{ Bad-input rejection

subtest 'unpack_footer rejects bad inputs' => sub {
    is(unpack_footer(undef),        undef, 'undef rejected');
    is(unpack_footer(''),           undef, 'empty rejected');
    is(unpack_footer('x' x 63),     undef, '63 bytes rejected');
    is(unpack_footer('x' x 65),     undef, '65 bytes rejected');

    my $good = pack_footer(
        format_id   => 'TAR',
        meta_offset => 0,
        meta_size   => 0,
        body_size   => 0,
    );

    # Corrupt head magic.
    my $bad_head = $good;
    substr($bad_head, 0, 8) = 'XXXXFOOT';
    is(unpack_footer($bad_head), undef, 'bad head magic rejected');

    # Corrupt tail magic.
    my $bad_tail = $good;
    substr($bad_tail, 56, 8) = 'XXXXTAIL';
    is(unpack_footer($bad_tail), undef, 'bad tail magic rejected');
};

subtest 'pack_footer croaks on missing required fields' => sub {
    like(
        dies { pack_footer(meta_offset => 0, meta_size => 0, body_size => 0) },
        qr/missing required field 'format_id'/,
        'missing format_id',
    );
    like(
        dies { pack_footer(format_id => 'TAR', meta_size => 0, body_size => 0) },
        qr/missing required field 'meta_offset'/,
        'missing meta_offset',
    );
    like(
        dies { pack_footer(format_id => 'TAR', meta_offset => 0, body_size => 0) },
        qr/missing required field 'meta_size'/,
        'missing meta_size',
    );
    like(
        dies { pack_footer(format_id => 'TAR', meta_offset => 0, meta_size => 0) },
        qr/missing required field 'body_size'/,
        'missing body_size',
    );
    like(
        dies { pack_footer(format_id => '', meta_offset => 0, meta_size => 0, body_size => 0) },
        qr/format_id must be 1\.\.4 bytes/,
        'empty format_id rejected',
    );
    like(
        dies { pack_footer(format_id => 'TOOLONG', meta_offset => 0, meta_size => 0, body_size => 0) },
        qr/format_id must be 1\.\.4 bytes/,
        'over-long format_id rejected',
    );
};

# }}}

# {{{ crc32

subtest 'crc32_of matches reference value' => sub {
    is(crc32_of('hello world'), 0x0d4a1185, 'crc32("hello world")');
    is(crc32_of(''),            0,          'crc32("") = 0');
};

# }}}

# {{{ append_meta / read_meta_from_path

sub _new_temp_with_body {
    my ($body) = @_;
    $body = 'BODY-PRELUDE-XYZ' unless defined $body;
    my ($fh, $path) = tempfile('yath-footer-XXXXXX', UNLINK => 1, TMPDIR => 1);
    binmode $fh;
    print $fh $body;
    close $fh;
    return ($path, length $body);
}

subtest 'append_meta plaintext round-trip' => sub {
    my ($path, $body_size) = _new_temp_with_body();
    my $meta = '{"format":"tar.zidx","run":{"id":"abc"}}';

    my $trailer = append_meta(
        $path, $meta,
        format_id => FORMAT_ID_TAR,
        body_size => $body_size,
    );

    is(length($trailer), FOOTER_SIZE, 'returned trailer is 64 bytes');

    # File should now be: body + meta + trailer.
    is(-s $path, $body_size + length($meta) + FOOTER_SIZE, 'final file size');

    my $footer = read_footer_from_path($path);
    ok($footer, 'read_footer_from_path returns footer');
    is($footer->{format_id},   'TAR',           'format_id');
    is($footer->{flags},       0,               'no compress flag');
    is($footer->{version},     FOOTER_VERSION,  'version');
    is($footer->{meta_offset}, $body_size,      'meta_offset = body_size');
    is($footer->{meta_size},   length($meta),   'meta_size');
    is($footer->{body_size},   $body_size,      'body_size echoed');
    is($footer->{format_ptr},  0,               'format_ptr default 0');
    is($footer->{meta_crc32},  crc32_of($meta), 'meta crc32');

    # Manually read meta from file at meta_offset using the
    # footer-only path (proving the external-reader contract).
    open(my $fh, '<', $path) or die $!;
    binmode $fh;
    seek($fh, $footer->{meta_offset}, SEEK_SET) or die $!;
    my $buf = '';
    read($fh, $buf, $footer->{meta_size});
    close $fh;
    is($buf, $meta, 'raw bytes at meta_offset match input');

    my ($read_meta, $f2) = read_meta_from_path($path);
    is($read_meta, $meta, 'read_meta_from_path returns plaintext');
    is($f2->{format_id}, 'TAR', 'returned footer matches');

    ok(has_footer($path), 'has_footer is truthy');
};

subtest 'append_meta with compressed flag' => sub {
    my ($path, $body_size) = _new_temp_with_body('SQLITE-PRETEND-BODY');
    my $meta = '{"this":"is some json text that hopefully compresses"}' x 20;

    my $trailer = append_meta(
        $path, $meta,
        format_id  => FORMAT_ID_SQL,
        compressed => 1,
        body_size  => $body_size,
        format_ptr => 0,
    );

    my $footer = unpack_footer($trailer);
    ok($footer, 'unpack returned trailer');
    is($footer->{format_id}, 'SQL', 'format_id = SQL');
    ok($footer->{flags} & FLAG_META_COMPRESSED, 'compress flag set');

    my ($read_meta, $f2) = read_meta_from_path($path);
    is($read_meta, $meta, 'read_meta_from_path returns decompressed plaintext');
    ok($f2->{flags} & FLAG_META_COMPRESSED, 'flag still visible to caller');

    # And the compressed bytes should round-trip through Zstd directly.
    open(my $fh, '<', $path) or die $!;
    binmode $fh;
    seek($fh, $f2->{meta_offset}, SEEK_SET) or die $!;
    my $raw = '';
    read($fh, $raw, $f2->{meta_size});
    close $fh;
    is(decompress_blob($raw), $meta, 'on-disk bytes are valid zstd of meta');
};

subtest 'read_meta_from_path detects crc tampering' => sub {
    my ($path, $body_size) = _new_temp_with_body();
    my $meta = '{"x":1}';

    append_meta(
        $path, $meta,
        format_id => FORMAT_ID_TAR,
        body_size => $body_size,
    );

    # Corrupt one byte inside the meta region (which is right at body_size).
    open(my $fh, '+<', $path) or die $!;
    binmode $fh;
    seek($fh, $body_size, SEEK_SET) or die $!;
    my $orig = '';
    read($fh, $orig, 1);
    seek($fh, $body_size, SEEK_SET) or die $!;
    print $fh chr((ord($orig) ^ 0xFF) & 0xFF);
    close $fh;

    like(
        dies { read_meta_from_path($path) },
        qr/crc32 mismatch/i,
        'corruption detected via crc',
    );
};

subtest 'format_ptr round-trips a non-zero value' => sub {
    my ($path, $body_size) = _new_temp_with_body();
    my $meta = '{"y":2}';

    append_meta(
        $path, $meta,
        format_id  => FORMAT_ID_TAR,
        body_size  => $body_size + 32, # tar convention: zidx_footer_offset + 32
        format_ptr => $body_size,      # offset of tar.zidx footer
    );

    my $footer = read_footer_from_path($path);
    ok($footer, 'footer read');
    is($footer->{format_ptr}, $body_size,        'format_ptr round-trips');
    is($footer->{body_size},  $body_size + 32,   'body_size round-trips');
};

subtest 'has_footer / read_footer_from_path on tiny file' => sub {
    my ($fh, $path) = tempfile('yath-footer-tiny-XXXXXX', UNLINK => 1, TMPDIR => 1);
    binmode $fh;
    print $fh 'short';
    close $fh;

    is(read_footer_from_path($path), undef, 'tiny file: no footer');
    is(has_footer($path),            0,     'tiny file: has_footer false');
};

subtest 'read_meta_from_path on file without trailer croaks' => sub {
    my ($path, undef) = _new_temp_with_body('A' x 200);
    like(
        dies { read_meta_from_path($path) },
        qr/no valid YATHFOOT trailer/,
        'absent trailer rejected',
    );
};

# }}}

sub _show {
    my ($s) = @_;
    $s =~ s/\0/\\0/g;
    return $s;
}

done_testing;
