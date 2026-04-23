package App::Yath2::LogArchive::SevenZip::External;
use strict;
use warnings;

use IPC::Cmd qw/can_run/;

use Carp qw/croak/;
use Role::Tiny::With;

use parent 'App::Yath2::LogArchive';
use Object::HashBase qw/path format _listed/;

with 'App::Yath2::LogArchive::Role::Source';

use constant SEVENZ_BIN => scalar can_run('7z');

sub viable { defined SEVENZ_BIN }

sub list_files {
    my $self = shift;
    return @{$self->{+_LISTED}} if $self->{+_LISTED};

    my $bin = SEVENZ_BIN or croak "no 7z";
    open(my $fh, '-|', $bin, 'l', '-ba', '-slt', $self->{+PATH})
        or croak "7z l: $!";

    my @files;
    my %entry;
    while (my $line = <$fh>) {
        chomp $line;
        if ($line eq '') {
            push @files => $entry{Path}
                if defined $entry{Path}
                && length $entry{Path}
                && (!defined $entry{Attributes} || $entry{Attributes} !~ /D/);
            %entry = ();
            next;
        }
        if ($line =~ /^([^=]+?)\s*=\s*(.*)$/) {
            $entry{$1} = $2;
        }
    }
    close $fh;

    push @files => $entry{Path}
        if defined $entry{Path}
        && length $entry{Path}
        && (!defined $entry{Attributes} || $entry{Attributes} !~ /D/);

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
    my $bin = SEVENZ_BIN or croak "no 7z";
    open(my $fh, '-|', $bin, 'x', '-so', $self->{+PATH}, $rel)
        or croak "7z x -so: $!";
    return $fh;
}

sub close { }

1;
