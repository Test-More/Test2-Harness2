package App::Yath2::LogArchive::TarZIdx::Util;
use strict;
use warnings;

use IPC::Cmd qw/can_run/;

use Carp qw/croak/;
use Exporter qw/import/;
use Fcntl qw/SEEK_SET SEEK_END/;
use IPC::Open2 qw/open2/;
use Symbol qw/gensym/;

use App::Yath2::LogArchive::Format qw/TAR_ZIDX_MAGIC TAR_ZIDX_FOOTER_LEN/;

our @EXPORT_OK = qw/
    pack_ustar_header
    pack_footer
    parse_footer
    pad_to_block
    BLOCK_SIZE
    INDEX_ENTRY_NAME
    zstd_bin
    unzstd_bin
    have_compress_zstd
    zstd_compress
    zstd_decompress
/;

use constant BLOCK_SIZE        => 512;
use constant INDEX_ENTRY_NAME  => '__index__.json.zst';
use constant HAVE_COMPRESS_ZSTD => eval { require Compress::Zstd; 1 } ? 1 : 0;

use constant ZSTD_BIN   => scalar can_run('zstd');
use constant UNZSTD_BIN => scalar can_run('unzstd') // scalar can_run('zstd');

sub zstd_bin   { ZSTD_BIN }
sub unzstd_bin { UNZSTD_BIN }
sub have_compress_zstd { HAVE_COMPRESS_ZSTD }

sub pack_ustar_header {
    my ($name, $size) = @_;

    my ($base, $prefix) = ($name, '');
    if (length($name) > 100) {
        my $i = rindex($name, '/', 154);
        croak "tar.zidx: pathname too long for ustar: $name"
            if $i < 0
            || (length($name) - $i - 1) > 100
            || $i > 155;
        $prefix = substr($name, 0, $i);
        $base   = substr($name, $i + 1);
    }

    my $hdr = pack(
        'a100 a8 a8 a8 a12 a12 A8 a1 a100 a6 a2 a32 a32 a8 a8 a155 x12',
        $base,
        sprintf('%07o',  oct('0644')) . "\0",
        sprintf('%07o',  0) . "\0",
        sprintf('%07o',  0) . "\0",
        sprintf('%011o', $size) . "\0",
        sprintf('%011o', time) . "\0",
        '        ',
        '0',
        '',
        "ustar\0",
        '00',
        '',
        '',
        sprintf('%07o', 0) . "\0",
        sprintf('%07o', 0) . "\0",
        $prefix,
    );

    my $sum = unpack('%16C*', $hdr);
    substr($hdr, 148, 8) = sprintf('%06o', $sum) . "\0 ";

    croak "tar.zidx: header pack produced unexpected length"
        unless length($hdr) == BLOCK_SIZE;

    return $hdr;
}

sub pad_to_block {
    my ($len) = @_;
    my $rem = $len % BLOCK_SIZE;
    return $rem ? (BLOCK_SIZE - $rem) : 0;
}

sub pack_footer {
    my ($idx_offset, $idx_size) = @_;
    return pack('a8 Q< Q< Q<', TAR_ZIDX_MAGIC, $idx_offset, $idx_size, 0);
}

sub parse_footer {
    my ($buf) = @_;
    croak "tar.zidx: short footer" unless length($buf) == TAR_ZIDX_FOOTER_LEN;
    my ($magic, $idx_offset, $idx_size, undef) = unpack('a8 Q< Q< Q<', $buf);
    croak "tar.zidx: bad footer magic" unless $magic eq TAR_ZIDX_MAGIC;
    return ($idx_offset, $idx_size);
}

sub zstd_compress {
    my ($bytes) = @_;
    return Compress::Zstd::compress($bytes) if HAVE_COMPRESS_ZSTD;

    my $bin = ZSTD_BIN
        or croak "tar.zidx: need either Compress::Zstd or the zstd binary";

    my ($in, $out);
    my $err = gensym;
    my $pid = open2($out, $in, $bin, '-q', '--no-progress', '-');
    binmode $in;
    binmode $out;
    print $in $bytes;
    close $in;
    local $/;
    my $compressed = <$out>;
    close $out;
    waitpid $pid, 0;
    croak "tar.zidx: zstd exited $?" if $?;
    return $compressed;
}

sub zstd_decompress {
    my ($bytes) = @_;
    if (HAVE_COMPRESS_ZSTD) {
        my $out = Compress::Zstd::decompress($bytes);
        croak "tar.zidx: Compress::Zstd::decompress failed" unless defined $out;
        return $out;
    }

    my $bin = UNZSTD_BIN
        or croak "tar.zidx: need either Compress::Zstd or zstd/unzstd binary";

    my ($in, $out);
    my $pid = open2($out, $in, $bin, '-q', '-d', '-');
    binmode $in;
    binmode $out;
    print $in $bytes;
    close $in;
    local $/;
    my $plain = <$out>;
    close $out;
    waitpid $pid, 0;
    croak "tar.zidx: unzstd exited $?" if $?;
    return $plain;
}

1;
