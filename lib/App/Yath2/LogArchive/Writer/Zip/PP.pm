package App::Yath2::LogArchive::Writer::Zip::PP;
use strict;
use warnings;

use Carp qw/croak/;
use Role::Tiny::With;

use Object::HashBase qw/source path format/;

with 'App::Yath2::LogArchive::Role::Writer';

use constant HAVE_ARCHIVE_ZIP => eval {
    require Archive::Zip;
    Archive::Zip->import(qw/AZ_OK/);
    1;
} ? 1 : 0;

sub viable { HAVE_ARCHIVE_ZIP }

sub write_archive {
    my $self = shift;

    my $src = $self->{+SOURCE};
    my $out = $self->{+PATH};
    my $tmp = "$out.tmp.$$";

    my $z = Archive::Zip->new;
    $z->addTree($src, '');
    $z->writeToFileNamed($tmp) == Archive::Zip::AZ_OK()
        or croak "Archive::Zip writeToFileNamed failed";

    rename($tmp, $out) or croak "rename $tmp -> $out: $!";
    return $out;
}

1;
