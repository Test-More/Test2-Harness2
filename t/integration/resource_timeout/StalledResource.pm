package StalledResource;
use strict;
use warnings;

use parent 'Test2::Harness2::Runner::Resource';

sub available {
    my $self = shift;
    my ($task) = @_;

    # Allow the first task through, block everything after
    return 0 if $self->{_started};
    return 1;
}

sub assign {
    my $self = shift;
    my ($task, $state) = @_;
    $state->{record} = 1;
}

sub record {
    my $self = shift;
    my ($job_id, $val) = @_;
    $self->{_started}++;
}

sub release {
    my $self = shift;
    my ($job_id) = @_;
}

1;
