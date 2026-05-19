package Test2::Harness2::Util::Zstd;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use File::Spec ();
use File::Temp qw/tempfile/;
use Importer Importer => 'import';

use Compress::Zstd ();

our @EXPORT_OK = qw{
    compress_blob
    decompress_blob
    open_zstd_writer
    open_zstd_reader
    open_zstd_reader_fh
    compress_file_atomic
    decompress_file
    zstd_frame_size
    ZSTD_FRAME_MAGIC
};

use constant ZSTD_FRAME_MAGIC => "\x28\xB5\x2F\xFD";

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::Zstd - zstd helpers (compress, decompress,
append-safe writer, line reader).

=head1 DESCRIPTION

Single-purpose helper module wrapping L<Compress::Zstd>. Compression
is always in-process via the Perl module -- there is no external
C<zstd> binary fallback. Helpers run at the L<Compress::Zstd> library
default level (3); the dictionary path was benchmarked at under 35%
improvement over dict-less and dropped, so none of the helpers accept
C<dict_*> options.

The streaming writer/reader pair speaks the "one self-contained zstd
frame per record" shape used for C<.jsonl.zst> live event tailing:
each call writes one zstd frame, so concurrent appenders are safe as
long as a frame fits in C<PIPE_BUF> (4 KiB on Linux).

=head1 SYNOPSIS

    use Test2::Harness2::Util::Zstd qw{
        compress_blob decompress_blob
        compress_file_atomic decompress_file
        open_zstd_writer open_zstd_reader
    };

    my $frame = compress_blob($bytes);
    my $back  = decompress_blob($frame);

    compress_file_atomic('foo.json.zst', $json_text);
    my $bytes = decompress_file('foo.json.zst');

    my $w = open_zstd_writer('events.jsonl.zst');
    $w->print($json_line, "\n");

    my $r = open_zstd_reader('events.jsonl.zst');
    while (defined(my $line = $r->readline)) { ... }

=head1 EXPORTS

=cut

=over 4

=item compress_blob

=item compress_blob($bytes) :Bytes

One-shot compress.

=back

=cut

sub compress_blob {
    my ($bytes) = @_;
    return Compress::Zstd::compress($bytes);
}

=over 4

=item decompress_blob

=item decompress_blob($bytes) :Bytes

Symmetric one-shot decompress. Croaks on malformed input.

=back

=cut

sub decompress_blob {
    my ($bytes) = @_;
    my $out = Compress::Zstd::decompress($bytes);
    croak "Compress::Zstd::decompress failed" unless defined $out;
    return $out;
}

=over 4

=item compress_file_atomic

=item compress_file_atomic($path, $bytes) :Path

Compress C<$bytes> as one zstd frame, write to a sibling tempfile in
the same directory, then atomic-rename to C<$path>.

=back

=cut

sub compress_file_atomic {
    my ($path, $bytes) = @_;

    croak "path is required"  unless defined $path;
    croak "bytes is required" unless defined $bytes;

    my $compressed = compress_blob($bytes);
    my $dir        = _dirname($path);
    my ($fh, $tmp) = tempfile("zstd-XXXXXX", DIR => $dir, UNLINK => 0);
    binmode $fh;
    print $fh $compressed
        or do { close $fh; unlink $tmp; croak "write to '$tmp' failed: $!" };
    close($fh)
        or do { unlink $tmp; croak "close '$tmp' failed: $!" };
    rename($tmp, $path)
        or do { unlink $tmp; croak "rename '$tmp' -> '$path' failed: $!" };

    return $path;
}

=over 4

=item decompress_file

=item decompress_file($path) :Bytes

Read C<$path>, decompress, return the plaintext.

=back

=cut

sub decompress_file {
    my ($path) = @_;

    open(my $fh, '<', $path) or croak "open '$path': $!";
    binmode $fh;
    local $/;
    my $bytes = <$fh>;
    close $fh;

    return decompress_blob($bytes);
}

=over 4

=item open_zstd_writer

=item $w = open_zstd_writer($path) :Object

Return a L<Test2::Harness2::Util::Zstd::Writer> that appends one
self-contained zstd frame per C<print> / C<say> call.

=back

=cut

sub open_zstd_writer {
    my ($path) = @_;
    require Test2::Harness2::Util::Zstd::Writer;
    return Test2::Harness2::Util::Zstd::Writer->_open($path);
}

=over 4

=item open_zstd_reader

=item $r = open_zstd_reader($path) :Object

Return a L<Test2::Harness2::Util::Zstd::Reader> whose
C<< ->readline >> yields one decoded frame at a time.

=back

=cut

sub open_zstd_reader {
    my ($path) = @_;
    require Test2::Harness2::Util::Zstd::Reader;
    return Test2::Harness2::Util::Zstd::Reader->_open($path);
}

=over 4

=item open_zstd_reader_fh

=item $r = open_zstd_reader_fh($fh) :Object

Same as L</open_zstd_reader> but takes a pre-opened, seekable file
handle (including a scalar-fh opened against an in-memory zstd-framed
byte string).

=back

=cut

sub open_zstd_reader_fh {
    my ($fh) = @_;
    require Test2::Harness2::Util::Zstd::Reader;
    return Test2::Harness2::Util::Zstd::Reader->_open_fh($fh);
}

=over 4

=item zstd_frame_size

=item $size = zstd_frame_size($bytes)

Return the on-disk byte length of the first zstd frame in C<$bytes>,
or C<undef> if C<$bytes> does not yet contain a complete frame.
Implements RFC 8878 frame_header parsing so consumers can find frame
boundaries without scanning for magic (which can race on partial
writes).

=back

=cut

sub zstd_frame_size {
    my ($bytes) = @_;

    return undef if length($bytes) < 6;
    return undef unless substr($bytes, 0, 4) eq ZSTD_FRAME_MAGIC;

    my $pos  = 4;
    my $desc = ord(substr($bytes, $pos, 1));
    $pos++;

    my $fcs_flag       = ($desc >> 6) & 0x3;
    my $single_segment = ($desc >> 5) & 0x1;
    my $checksum_flag  = ($desc >> 2) & 0x1;
    my $dict_id_flag   = $desc & 0x3;

    $pos = _zstd_skip_frame_header_tail($bytes, $pos, $fcs_flag, $single_segment, $dict_id_flag);
    return undef unless defined $pos;

    $pos = _zstd_walk_blocks($bytes, $pos);
    return undef unless defined $pos;

    if ($checksum_flag) {
        return undef if length($bytes) < $pos + 4;
        $pos += 4;
    }

    return $pos;
}

sub _zstd_skip_frame_header_tail {
    my ($bytes, $pos, $fcs_flag, $single_segment, $dict_id_flag) = @_;

    if (!$single_segment) {
        return undef if length($bytes) < $pos + 1;
        $pos++;
    }

    my @dict_id_bytes = (0, 1, 2, 4);
    my $did_size      = $dict_id_bytes[$dict_id_flag];
    return undef if length($bytes) < $pos + $did_size;
    $pos += $did_size;

    my @fcs_sizes = (
        $single_segment ? 1 : 0,
        2,
        4,
        8,
    );
    my $fcs_size = $fcs_sizes[$fcs_flag];
    return undef if length($bytes) < $pos + $fcs_size;
    $pos += $fcs_size;

    return $pos;
}

sub _zstd_walk_blocks {
    my ($bytes, $pos) = @_;

    while (1) {
        return undef if length($bytes) < $pos + 3;
        my $b0 = ord(substr($bytes, $pos,     1));
        my $b1 = ord(substr($bytes, $pos + 1, 1));
        my $b2 = ord(substr($bytes, $pos + 2, 1));

        my $block_header = $b0 | ($b1 << 8) | ($b2 << 16);
        my $last_block   = $block_header & 0x1;
        my $block_type   = ($block_header >> 1) & 0x3;
        my $block_size   = $block_header >> 3;

        $pos += 3;

        if ($block_type == 1) {
            return undef if length($bytes) < $pos + 1;
            $pos += 1;
        }
        else {
            return undef if length($bytes) < $pos + $block_size;
            $pos += $block_size;
        }

        last if $last_block;
    }

    return $pos;
}

sub _dirname {
    my ($path) = @_;
    my (undef, $dir) = File::Spec->splitpath($path);
    return length($dir) ? $dir : '.';
}

1;

__END__

=pod

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
