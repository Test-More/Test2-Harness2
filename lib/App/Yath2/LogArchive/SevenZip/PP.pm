package App::Yath2::LogArchive::SevenZip::PP;
use strict;
use warnings;

use Carp qw/croak/;
use Role::Tiny::With;

use parent 'App::Yath2::LogArchive';
use Object::HashBase qw/path format _archive/;

with 'App::Yath2::LogArchive::Role::Source';

use constant HAVE_DEPS => eval { require Archive::SevenZip; 1 } ? 1 : 0;

sub viable { HAVE_DEPS }

sub _archive_obj {
    my $self = shift;
    return $self->{+_ARCHIVE} //= do {
        my $a = Archive::SevenZip->new(archivename => $self->{+PATH});
        $a;
    };
}

sub list_files {
    my $self = shift;
    return grep { !m{/\z} } map { $_->{Name} } $self->_archive_obj->members;
}

sub has_file {
    my ($self, $rel) = @_;
    my $m = $self->_archive_obj->memberNamed($rel) or return 0;
    return 1;
}

sub read_file {
    my ($self, $rel) = @_;
    my $data = $self->_archive_obj->content(name => $rel);
    croak "no such file '$rel' in archive" unless defined $data;
    open(my $fh, '<', \$data) or croak "open scalar: $!";
    return $fh;
}

sub close {
    my $self = shift;
    delete $self->{+_ARCHIVE};
}

1;
