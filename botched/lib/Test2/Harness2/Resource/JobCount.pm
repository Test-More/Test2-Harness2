package Test2::Harness2::Resource::JobCount;
use strict;
use warnings;

our $VERSION = '2.000012';

use parent 'Test2::Harness2::Resource';

use Test2::Harness2::Util::HashBase qw/job_count _in_use/;

sub can_use_globally { 1 }

sub init {
    my ($self) = @_;
    $self->{+_IN_USE} //= 0;
}

sub available {
    my ($self) = @_;
    return $self->{+_IN_USE} < $self->{+JOB_COUNT} ? 1 : 0;
}

sub applicable { 1 }

sub assign {
    my ($self) = @_;
    $self->{+_IN_USE}++;
}

sub release {
    my ($self) = @_;
    $self->{+_IN_USE}-- if $self->{+_IN_USE} > 0;
}

sub spawn_service { undef }

1;
