package App::Yath2::LogArchive::Zip::External;
use strict;
use warnings;

use IPC::Cmd qw/can_run/;

use Carp qw/croak/;
use Role::Tiny::With;

use parent 'App::Yath2::LogArchive';
use Object::HashBase qw/path format _listed/;

with 'App::Yath2::LogArchive::Role::Source';

use constant UNZIP_BIN => scalar can_run('unzip');

sub viable { defined UNZIP_BIN }

sub list_files {
    my $self = shift;
    return @{$self->{+_LISTED}} if $self->{+_LISTED};

    my $bin = UNZIP_BIN or croak "no unzip";
    open(my $fh, '-|', $bin, '-Z1', $self->{+PATH})
        or croak "unzip -Z1: $!";
    my @files;
    while (my $line = <$fh>) {
        chomp $line;
        next unless length $line;
        next if $line =~ m{/\z};
        push @files => $line;
    }
    close $fh;
    $self->{+_LISTED} = \@files;
    return @files;
}

sub has_file {
    my ($self, $rel) = @_;
    my %set = map { $_ => 1 } $self->list_files;
    return $set{$rel} ? 1 : 0;
}

sub read_file {
    my ($self, $rel) = @_;
    my $bin = UNZIP_BIN or croak "no unzip";
    open(my $fh, '-|', $bin, '-p', $self->{+PATH}, $rel)
        or croak "unzip -p: $!";
    return $fh;
}

sub close { }

1;
