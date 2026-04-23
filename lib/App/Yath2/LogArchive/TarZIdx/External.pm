package App::Yath2::LogArchive::TarZIdx::External;
use strict;
use warnings;

use Carp qw/croak/;
use Fcntl qw/SEEK_SET SEEK_END/;
use Role::Tiny::With;

use App::Yath2::LogArchive::Format qw/TAR_ZIDX_FOOTER_LEN/;
use App::Yath2::LogArchive::TarZIdx::Util qw/
    parse_footer
    zstd_decompress
    zstd_bin
    unzstd_bin
    have_compress_zstd
/;
use Test2::Harness2::Util::JSON qw/decode_json/;

use parent 'App::Yath2::LogArchive';
use Object::HashBase qw/path format _index/;

with 'App::Yath2::LogArchive::Role::Source';

sub viable { defined zstd_bin() || defined unzstd_bin() || have_compress_zstd() }

sub _build_index {
    my $self = shift;
    return $self->{+_INDEX} if $self->{+_INDEX};

    open(my $fh, '<', $self->{+PATH}) or croak "open $self->{+PATH}: $!";
    binmode $fh;

    my $size = -s $self->{+PATH};
    croak "tar.zidx: file too small" if $size < TAR_ZIDX_FOOTER_LEN;

    seek($fh, -TAR_ZIDX_FOOTER_LEN, SEEK_END) or croak "seek footer: $!";
    my $foot;
    read($fh, $foot, TAR_ZIDX_FOOTER_LEN) == TAR_ZIDX_FOOTER_LEN
        or croak "short footer read";

    my ($idx_offset, $idx_size) = parse_footer($foot);

    seek($fh, $idx_offset, SEEK_SET) or croak "seek index: $!";
    my $idx_bytes;
    read($fh, $idx_bytes, $idx_size) == $idx_size
        or croak "short index read";
    close $fh;

    my $json = zstd_decompress($idx_bytes);
    $self->{+_INDEX} = decode_json($json);
    return $self->{+_INDEX};
}

sub list_files {
    my $self = shift;
    return keys %{$self->_build_index};
}

sub has_file {
    my ($self, $rel) = @_;
    return exists $self->_build_index->{$rel} ? 1 : 0;
}

sub read_file {
    my ($self, $rel) = @_;
    my $entry = $self->_build_index->{$rel}
        or croak "no such file '$rel' in archive";

    open(my $fh, '<', $self->{+PATH}) or croak "open $self->{+PATH}: $!";
    binmode $fh;
    seek($fh, $entry->{offset}, SEEK_SET) or croak "seek data: $!";
    my $compressed;
    read($fh, $compressed, $entry->{size}) == $entry->{size}
        or croak "short data read for '$rel'";
    close $fh;

    my $plain = zstd_decompress($compressed);
    open(my $sfh, '<', \$plain) or croak "open scalar: $!";
    return $sfh;
}

sub close {
    my $self = shift;
    delete $self->{+_INDEX};
}

1;
