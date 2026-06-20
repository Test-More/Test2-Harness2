package UnavailableResource;
use strict;
use warnings;

use Object::HashBase qw/&Test2::Harness2::Runner::Resource/;

sub available {
    my $self = shift;
    my ($task) = @_;

    # Resource is permanently unavailable for all tests.
    return -1;
}

sub assign {}
sub record {}
sub release {}

1;
