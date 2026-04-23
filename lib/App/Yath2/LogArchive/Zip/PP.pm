package App::Yath2::LogArchive::Zip::PP;
use strict;
use warnings;

use Carp qw/croak/;
use Role::Tiny::With;

use parent 'App::Yath2::LogArchive';
use Object::HashBase qw/path format _archive/;

with 'App::Yath2::LogArchive::Role::Source';

use constant HAVE_ARCHIVE_ZIP => eval {
    require Archive::Zip;
    Archive::Zip->import(qw/AZ_OK/);
    1;
} ? 1 : 0;

sub viable { HAVE_ARCHIVE_ZIP }

sub _archive_obj {
    my $self = shift;
    return $self->{+_ARCHIVE} //= do {
        my $z = Archive::Zip->new;
        $z->read($self->{+PATH}) == Archive::Zip::AZ_OK()
            or croak "Archive::Zip read failed";
        $z;
    };
}

sub list_files {
    my $self = shift;
    return grep { !m{/\z} } $self->_archive_obj->memberNames;
}

sub has_file {
    my ($self, $rel) = @_;
    return defined $self->_archive_obj->memberNamed($rel) ? 1 : 0;
}

sub read_file {
    my ($self, $rel) = @_;
    my $m = $self->_archive_obj->memberNamed($rel)
        or croak "no such file '$rel' in zip";
    my $data = $m->contents;
    open(my $fh, '<', \$data) or croak "open scalar: $!";
    return $fh;
}

sub close {
    my $self = shift;
    delete $self->{+_ARCHIVE};
}

1;
