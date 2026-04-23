package App::Yath2::LogArchive::Tar::PP;
use strict;
use warnings;

use Carp qw/croak/;
use Role::Tiny::With;

use parent 'App::Yath2::LogArchive';
use Object::HashBase qw/path format _archive _name_map/;

with 'App::Yath2::LogArchive::Role::Source';

use constant HAVE_ARCHIVE_TAR => eval { require Archive::Tar; 1 } ? 1 : 0;

sub viable { HAVE_ARCHIVE_TAR }

sub _archive_obj {
    my $self = shift;
    return $self->{+_ARCHIVE} //= do {
        my $t = Archive::Tar->new;
        $t->read($self->{+PATH})
            or croak "Archive::Tar read failed: " . Archive::Tar->error;
        $t;
    };
}

sub _build_index {
    my $self = shift;
    return if $self->{+_NAME_MAP};
    my $t = $self->_archive_obj;
    my %map;
    for my $name ($t->list_files) {
        my ($f) = $t->get_files($name);
        next unless $f;
        next if $f->is_dir;
        my $clean = $name;
        $clean =~ s{^\./}{};
        $map{$clean} = $name;
    }
    $self->{+_NAME_MAP} = \%map;
    return;
}

sub list_files {
    my $self = shift;
    $self->_build_index;
    return keys %{$self->{+_NAME_MAP}};
}

sub has_file {
    my ($self, $rel) = @_;
    $self->_build_index;
    return exists $self->{+_NAME_MAP}{$rel} ? 1 : 0;
}

sub read_file {
    my ($self, $rel) = @_;
    $self->_build_index;
    my $name = $self->{+_NAME_MAP}{$rel}
        // croak "no such file '$rel' in archive";
    my ($f) = $self->_archive_obj->get_files($name);
    croak "no such file '$rel' in archive" unless $f;
    my $data = $f->get_content;
    open(my $fh, '<', \$data) or croak "open scalar: $!";
    return $fh;
}

sub close {
    my $self = shift;
    delete $self->{+_ARCHIVE};
}

1;
