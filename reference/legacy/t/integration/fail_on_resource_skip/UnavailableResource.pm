package UnavailableResource;
use strict;
use warnings;

use parent 'Test2::Harness::Runner::Resource';

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
