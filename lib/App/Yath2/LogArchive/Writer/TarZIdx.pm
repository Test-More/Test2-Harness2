package App::Yath2::LogArchive::Writer::TarZIdx;
use strict;
use warnings;

use Carp qw/croak/;
use File::Find ();
use File::Spec ();
use Role::Tiny::With;

use Object::HashBase qw/source path format/;

use App::Yath2::LogArchive::TarZIdx::Util qw/
    pack_ustar_header
    pack_footer
    pad_to_block
    BLOCK_SIZE
    INDEX_ENTRY_NAME
    zstd_compress
    zstd_bin
    have_compress_zstd
/;
use Test2::Harness2::Util::JSON qw/encode_json/;

with 'App::Yath2::LogArchive::Role::Writer';

sub viable {
    my ($class, $format) = @_;
    return 0 unless defined $format && $format eq 'tar.zidx';
    return defined zstd_bin() || have_compress_zstd();
}

sub write_archive {
    my $self = shift;

    my $src = $self->{+SOURCE};
    my $out = $self->{+PATH};
    my $tmp = "$out.tmp.$$";

    my $abs_src = File::Spec->rel2abs($src);
    croak "source '$src' is not a directory" unless -d $abs_src;

    open(my $fh, '>', $tmp) or croak "open $tmp: $!";
    binmode $fh;

    my @entries;
    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                return unless -f $_;
                my $rel = File::Spec->abs2rel($_, $abs_src);
                $rel =~ s{\\}{/}g;
                push @entries => [$rel, $_];
            },
        },
        $abs_src,
    );

    my %index;
    for my $pair (sort { $a->[0] cmp $b->[0] } @entries) {
        my ($rel, $abs) = @$pair;

        open(my $rfh, '<', $abs) or croak "open $abs: $!";
        binmode $rfh;
        local $/;
        my $raw = <$rfh>;
        close $rfh;

        my $compressed = zstd_compress($raw);
        my $stored     = "$rel.zst";

        my $hdr = pack_ustar_header($stored, length($compressed));
        print $fh $hdr;
        my $data_offset = tell $fh;
        print $fh $compressed;
        my $pad = pad_to_block(length $compressed);
        print $fh ("\0" x $pad) if $pad;

        $index{$rel} = {
            stored => $stored,
            offset => $data_offset,
            size   => length $compressed,
        };
    }

    my $idx_json       = encode_json(\%index);
    my $idx_compressed = zstd_compress($idx_json);
    my $idx_hdr        = pack_ustar_header(INDEX_ENTRY_NAME, length($idx_compressed));
    print $fh $idx_hdr;
    my $idx_offset = tell $fh;
    print $fh $idx_compressed;
    my $pad = pad_to_block(length $idx_compressed);
    print $fh ("\0" x $pad) if $pad;

    print $fh ("\0" x (BLOCK_SIZE * 2));

    print $fh pack_footer($idx_offset, length($idx_compressed));

    close $fh or croak "close $tmp: $!";

    rename($tmp, $out) or croak "rename $tmp -> $out: $!";
    return $out;
}

1;
