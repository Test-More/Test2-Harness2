package App::Yath2::LogArchive::Writer::Tar;
use strict;
use warnings;

use IPC::Cmd qw/can_run/;

use Carp qw/croak/;
use File::Find ();
use File::Spec ();
use Role::Tiny::With;

use Object::HashBase qw/source path format/;

with 'App::Yath2::LogArchive::Role::Writer';

use constant TAR_BIN              => scalar can_run('tar');
use constant HAVE_ARCHIVE_TAR     => eval { require Archive::Tar; 1 } ? 1 : 0;
use constant HAVE_IO_ZLIB         => eval { require IO::Zlib; 1 } ? 1 : 0;
use constant HAVE_BZIP2_COMPRESS  => eval { require IO::Compress::Bzip2; 1 } ? 1 : 0;

my %TAR_FLAG = (
    'tar'     => '-cf',
    'tar.gz'  => '-czf',
    'tar.bz2' => '-cjf',
);

sub viable {
    my ($class, $format) = @_;
    return 0 unless defined $format && exists $TAR_FLAG{$format};
    return 1 if defined TAR_BIN;
    return 0 unless HAVE_ARCHIVE_TAR;
    return 1 if $format eq 'tar';
    return 1 if $format eq 'tar.gz'  && HAVE_IO_ZLIB;
    return 1 if $format eq 'tar.bz2' && HAVE_BZIP2_COMPRESS;
    return 0;
}

sub write_archive {
    my $self = shift;

    my $src = $self->{+SOURCE};
    my $out = $self->{+PATH};
    my $fmt = $self->{+FORMAT};
    my $tmp = "$out.tmp.$$";

    my $flag = $TAR_FLAG{$fmt} // croak "unknown format '$fmt'";

    if (defined TAR_BIN) {
        system(TAR_BIN, $flag, $tmp, '-C', $src, '.') == 0
            or croak "tar $flag failed";
    }
    else {
        require Archive::Tar;
        my $t = Archive::Tar->new;
        my $abs_src = File::Spec->rel2abs($src);
        File::Find::find(
            {
                no_chdir => 1,
                wanted   => sub {
                    return unless -f $_;
                    my $rel = File::Spec->abs2rel($_, $abs_src);
                    $t->add_data($rel, do { local (@ARGV, $/) = ($_); <> });
                },
            },
            $abs_src,
        );
        my %compress = (
            'tar'     => 0,
            'tar.gz'  => Archive::Tar::COMPRESS_GZIP(),
            'tar.bz2' => Archive::Tar::COMPRESS_BZIP2(),
        );
        $t->write($tmp, $compress{$fmt})
            or croak "Archive::Tar write: " . Archive::Tar->error;
    }

    rename($tmp, $out) or croak "rename $tmp -> $out: $!";
    return $out;
}

1;
