package Test2::Harness2::TestFile;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Spec();

use Object::HashBase qw{
    <file
    <absolute
    <relative
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::TestFile';

sub init {
    my $self = shift;
    croak "'file' is required" unless defined $self->{+FILE};
    $self->{+ABSOLUTE} //= File::Spec->rel2abs($self->{+FILE});
    $self->{+RELATIVE} //= File::Spec->abs2rel($self->{+FILE});
}

1;

__END__

=head1 POD IS AUTO-GENERATED
