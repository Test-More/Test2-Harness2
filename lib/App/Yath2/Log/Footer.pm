package App::Yath2::Log::Footer;
use strict;
use warnings;

# Trailer pack template uses Q< (unsigned 64-bit little-endian); requires
# perl built with 64-bit native int. pack 'Q' itself is fixed at 8 bytes
# regardless of $Config{ivsize}, so this guard remains correct for any
# future >=64-bit perl (incl. hypothetical 128-bit builds).
use Config ();
BEGIN {
    die "App::Yath2::Log::Footer requires perl with 64-bit native int "
      . "(\$Config{ivsize} >= 8); this perl reports ivsize=$Config::Config{ivsize}.\n"
        if $Config::Config{ivsize} < 8;
}

our $VERSION = '2.000012';

use Carp qw/croak/;
use Fcntl qw/SEEK_SET SEEK_END/;
use Compress::Raw::Zlib ();

use Importer Importer => 'import';

our @EXPORT_OK = qw{
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

use constant FOOTER_MAGIC         => 'YATHFOOT';
use constant FOOTER_TAIL          => 'YATHTAIL';
use constant FOOTER_SIZE          => 64;
use constant FOOTER_VERSION       => 1;
use constant FORMAT_ID_TAR        => 'TAR';
use constant FORMAT_ID_SQL        => 'SQL';
use constant FLAG_META_COMPRESSED => 0x01;

# Pack template for the 64-byte trailer (all little-endian):
#
#   offset  size  field
#   0       8     magic            = ASCII 'YATHFOOT'
#   8       1     trailer_version  (u8, currently 1)
#   9       1     flags            (u8: bit0 = meta_compressed_zstd)
#   10      2     reserved         (u8 x2, zero)
#   12      4     format_id        (4 ASCII bytes, NUL-padded)
#   16      8     meta_offset      (u64) absolute file offset of meta payload
#   24      8     meta_size        (u64) meta payload byte count
#   32      4     meta_crc32       (u32) crc32 of meta payload bytes
#   36      4     reserved         (u32, zero)
#   40      8     body_size        (u64) sqlite: page_count*page_size;
#                                        tar: zidx_footer_offset + 32
#   48      8     format_ptr       (u64) tar: offset of zidx footer; sqlite: 0
#   56      8     trailer_self_magic = ASCII 'YATHTAIL'
#
# Total: 64 bytes.
use constant FOOTER_PACK_TEMPLATE => 'a8 C C a2 a4 Q< Q< L< L< Q< Q< a8';

sub pack_footer {
    my %p = @_;

    for my $k (qw/format_id meta_offset meta_size body_size/) {
        croak "pack_footer: missing required field '$k'"
            unless defined $p{$k};
    }

    my $fid = $p{format_id};
    croak "pack_footer: format_id must be 1..4 bytes, got '$fid'"
        if length($fid) < 1 || length($fid) > 4;
    $fid = pack('a4', $fid);

    my $version    = defined $p{version}    ? $p{version}    : FOOTER_VERSION;
    my $flags      = defined $p{flags}      ? $p{flags}      : 0;
    my $meta_crc32 = defined $p{meta_crc32} ? $p{meta_crc32} : 0;
    my $format_ptr = defined $p{format_ptr} ? $p{format_ptr} : 0;

    return pack(
        FOOTER_PACK_TEMPLATE,
        FOOTER_MAGIC,
        $version,
        $flags,
        "\0\0",
        $fid,
        $p{meta_offset}, $p{meta_size}, $meta_crc32, 0,
        $p{body_size},   $format_ptr,
        FOOTER_TAIL,
    );
}

sub unpack_footer {
    my ($bytes) = @_;

    return undef unless defined $bytes;
    return undef unless length($bytes) == FOOTER_SIZE;

    my (
        $magic, $version, $flags, $reserved2, $fid_raw,
        $meta_offset, $meta_size, $meta_crc32, $reserved4,
        $body_size, $format_ptr, $tail,
    ) = unpack(FOOTER_PACK_TEMPLATE, $bytes);

    return undef unless defined $magic && $magic eq FOOTER_MAGIC;
    return undef unless defined $tail  && $tail  eq FOOTER_TAIL;

    (my $format_id = $fid_raw) =~ s/\0+\z//;

    return {
        magic              => $magic,
        version            => $version,
        flags              => $flags,
        format_id          => $format_id,
        meta_offset        => $meta_offset,
        meta_size          => $meta_size,
        meta_crc32         => $meta_crc32,
        body_size          => $body_size,
        format_ptr         => $format_ptr,
        trailer_self_magic => $tail,
    };
}

sub crc32_of {
    my ($bytes) = @_;
    $bytes = '' unless defined $bytes;
    return Compress::Raw::Zlib::crc32($bytes, 0);
}

sub append_meta {
    my ($path, $meta_bytes, %opts) = @_;

    croak "append_meta: missing 'format_id'" unless defined $opts{format_id};
    croak "append_meta: missing 'body_size'" unless defined $opts{body_size};
    croak "append_meta: meta_bytes is required" unless defined $meta_bytes;

    my $payload = $meta_bytes;
    my $flags   = 0;
    if ($opts{compressed}) {
        require Test2::Harness2::Util::Zstd;
        $payload = Test2::Harness2::Util::Zstd::compress_blob($payload);
        $flags |= FLAG_META_COMPRESSED;
    }

    my $crc = crc32_of($payload);

    open(my $fh, '>>', $path)
        or croak "append_meta: open '$path' for append: $!";
    binmode $fh;

    my $meta_offset = -s $path;

    print $fh $payload
        or do { my $e = $!; close $fh; croak "append_meta: write meta to '$path': $e" };

    my $trailer = pack_footer(
        format_id   => $opts{format_id},
        flags       => $flags,
        meta_offset => $meta_offset,
        meta_size   => length($payload),
        meta_crc32  => $crc,
        body_size   => $opts{body_size},
        format_ptr  => defined $opts{format_ptr} ? $opts{format_ptr} : 0,
    );

    print $fh $trailer
        or do { my $e = $!; close $fh; croak "append_meta: write trailer to '$path': $e" };

    close $fh
        or croak "append_meta: close '$path': $!";

    return $trailer;
}

sub read_footer_from_path {
    my ($path) = @_;

    my $size = -s $path;
    return undef unless defined $size && $size >= FOOTER_SIZE;

    open(my $fh, '<', $path) or croak "read_footer_from_path: open '$path': $!";
    binmode $fh;
    seek($fh, -FOOTER_SIZE, SEEK_END)
        or do { my $e = $!; close $fh; croak "read_footer_from_path: seek '$path': $e" };

    my $buf = '';
    my $got = read($fh, $buf, FOOTER_SIZE);
    close $fh;

    return undef unless defined $got && $got == FOOTER_SIZE;

    return unpack_footer($buf);
}

sub read_meta_from_path {
    my ($path) = @_;

    my $footer = read_footer_from_path($path);
    croak "read_meta_from_path: no valid YATHFOOT trailer in '$path'"
        unless $footer;

    my $size = -s $path;
    croak "read_meta_from_path: file '$path' too small for declared meta region"
        if !defined $size
        || $footer->{meta_offset} + $footer->{meta_size} > $size - FOOTER_SIZE;

    open(my $fh, '<', $path) or croak "read_meta_from_path: open '$path': $!";
    binmode $fh;
    seek($fh, $footer->{meta_offset}, SEEK_SET)
        or do { my $e = $!; close $fh; croak "read_meta_from_path: seek '$path': $e" };

    my $buf = '';
    my $want = $footer->{meta_size};
    while ($want > 0) {
        my $got = read($fh, $buf, $want, length $buf);
        if (!defined $got) {
            my $e = $!;
            close $fh;
            croak "read_meta_from_path: read '$path': $e";
        }
        if ($got == 0) {
            close $fh;
            croak "read_meta_from_path: short read from '$path' (wanted $footer->{meta_size}, got " . length($buf) . ")";
        }
        $want -= $got;
    }
    close $fh;

    my $crc = crc32_of($buf);
    croak sprintf(
        "read_meta_from_path: crc32 mismatch in '%s' (expected 0x%08x, got 0x%08x)",
        $path, $footer->{meta_crc32}, $crc,
    ) if $crc != $footer->{meta_crc32};

    if ($footer->{flags} & FLAG_META_COMPRESSED) {
        require Test2::Harness2::Util::Zstd;
        $buf = Test2::Harness2::Util::Zstd::decompress_blob($buf);
    }

    return ($buf, $footer);
}

sub has_footer {
    my ($path) = @_;
    my $f = eval { read_footer_from_path($path) };
    return $f ? 1 : 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Log::Footer - Unified 64-byte YATHFOOT trailer for sealed yath archives.

=head1 SYNOPSIS

    use App::Yath2::Log::Footer qw{
        FORMAT_ID_TAR FORMAT_ID_SQL
        append_meta
        read_meta_from_path
        read_footer_from_path
        has_footer
    };

    # Append meta + trailer to a sealed archive.
    append_meta(
        $path,
        $meta_json_bytes,
        format_id  => FORMAT_ID_TAR,
        compressed => 1,
        body_size  => $body_size,
        format_ptr => $zidx_footer_offset,
    );

    # Read meta back without parsing the body.
    my ($meta_bytes, $footer) = read_meta_from_path($path);

=head1 DESCRIPTION

Defines a single 64-byte trailer (C<YATHFOOT>) appended to sealed
yath archives. The trailer carries a copy of C<meta.json> (optionally
zstd-compressed) plus a pointer back to format-specific data
(e.g. the tar.zidx index footer). Both tar.zidx and sealed-SQLite
C<.yath> files use this trailer so external tools can read
C<meta.json> by reading only the last 64 bytes plus the byte range
those 64 bytes point to -- no SQLite parser, no tar parser, no
zidx index parser required.

=head2 Trailer layout

All fields are little-endian. Total: 64 bytes.

    offset  size  field
    0       8     magic            = ASCII 'YATHFOOT'
    8       1     trailer_version  (u8, currently 1)
    9       1     flags            (u8: bit0 = meta_compressed_zstd)
    10      2     reserved         (zero)
    12      4     format_id        (4 ASCII bytes, NUL-padded; 'TAR\0', 'SQL\0', ...)
    16      8     meta_offset      (u64) absolute file offset of meta payload start
    24      8     meta_size        (u64) meta payload byte count (compressed bytes if compressed)
    32      4     meta_crc32       (u32) crc32 of meta payload bytes
    36      4     reserved         (zero)
    40      8     body_size        (u64) sqlite: page_count*page_size;
                                         tar:    zidx_footer_offset + 32
    48      8     format_ptr       (u64) tar: offset of zidx footer; sqlite: 0
    56      8     trailer_self_magic = ASCII 'YATHTAIL'

=head1 EXPORTS

Nothing is exported by default. Everything below is exportable on
request.

=over 4

=item FOOTER_MAGIC, FOOTER_TAIL, FOOTER_SIZE, FOOTER_VERSION

Constants for the head magic, tail magic, total trailer length (64),
and current trailer version (1).

=item FORMAT_ID_TAR, FORMAT_ID_SQL

Format-id constants for tar.zidx and sealed-SQLite archives.

=item FLAG_META_COMPRESSED

Flag bit set in the flags byte when the meta payload is zstd-compressed.

=item pack_footer(%fields) :Bytes

Returns the 64-byte trailer as a binary string. Required keys:
C<format_id>, C<meta_offset>, C<meta_size>, C<body_size>. Optional:
C<flags> (default 0), C<meta_crc32> (default 0), C<format_ptr>
(default 0), C<version> (default L</FOOTER_VERSION>).

=item unpack_footer($bytes) :HashRef|Undef

Returns a hashref of fields, or undef if C<$bytes> is the wrong
length, the head magic does not match, or the tail magic does not
match. The returned C<format_id> has trailing NULs stripped.

=item crc32_of($bytes) :U32

Wraps L<Compress::Raw::Zlib/crc32> with a zero seed.

=item append_meta($path, $meta_bytes, %opts) :Bytes

Opens C<$path> in append mode, writes C<$meta_bytes> (optionally
zstd-compressed first), then writes the 64-byte trailer. Required
opts: C<format_id>, C<body_size>. Optional: C<compressed> (bool;
sets L</FLAG_META_COMPRESSED>), C<format_ptr>. Returns the trailer
bytes for caller convenience.

=item read_footer_from_path($path) :HashRef|Undef

Reads the last 64 bytes of C<$path> and returns L</unpack_footer>'s
result. Returns undef when the file is smaller than 64 bytes.

=item read_meta_from_path($path) :($bytes, $footer)

Reads and validates the trailer, then reads, crc-checks, and (if the
flag is set) zstd-decompresses the meta payload. Returns the
plaintext meta bytes plus the footer hashref. Croaks on any
inconsistency (missing trailer, crc mismatch, short read).

=item has_footer($path) :Bool

True iff L</read_footer_from_path> succeeds.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
