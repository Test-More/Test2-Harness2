package App::Yath2::LogArchive::Tar::External;
use strict;
use warnings;

use IPC::Cmd qw/can_run/;

use Carp qw/croak/;
use Role::Tiny::With;

use parent 'App::Yath2::LogArchive';
use Object::HashBase qw/path format _listed _name_map/;

with 'App::Yath2::LogArchive::Role::Source';

use constant TAR_BIN => scalar can_run('tar');

sub viable {
    return defined TAR_BIN;
}

sub _list_flag { '-tf' }
sub _read_flag { '-xOf' }

sub list_files {
    my $self = shift;
    return @{$self->{+_LISTED}} if $self->{+_LISTED};

    my $bin = TAR_BIN or croak "no tar";
    open(my $fh, '-|', $bin, $self->_list_flag, $self->{+PATH})
        or croak "tar " . $self->_list_flag . ": $!";
    my @files;
    my %map;
    while (my $line = <$fh>) {
        chomp $line;
        next unless length $line;
        next if $line =~ m{/\z};
        my $clean = $line;
        $clean =~ s{^\./}{};
        push @files => $clean;
        $map{$clean} = $line;
    }
    close $fh;
    $self->{+_LISTED}   = \@files;
    $self->{+_NAME_MAP} = \%map;
    return @files;
}

sub has_file {
    my ($self, $rel) = @_;
    $self->list_files unless $self->{+_NAME_MAP};
    return exists $self->{+_NAME_MAP}{$rel} ? 1 : 0;
}

sub read_file {
    my ($self, $rel) = @_;
    my $bin = TAR_BIN or croak "no tar";
    $self->list_files unless $self->{+_NAME_MAP};
    my $name = $self->{+_NAME_MAP}{$rel} // $rel;
    open(my $fh, '-|', $bin, $self->_read_flag, $self->{+PATH}, $name)
        or croak "tar " . $self->_read_flag . " $name: $!";
    return $fh;
}

sub close { }

1;
