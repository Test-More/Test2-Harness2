package SchedulerKillerResource;
use strict;
use warnings;

use parent 'Test2::Harness::Runner::Resource';

use POSIX();

sub available { 1 }

sub assign {
    my $self = shift;
    my ($task, $state) = @_;
    $state->{record} = 1;
}

sub record {
    my $self = shift;
    $self->{_task_started} = 1;
}

sub release { }

sub tick {
    my $self = shift;
    return unless $self->{_task_started};

    my $mode = $ENV{SCHEDULER_DEATH_MODE} || return;

    if ($mode eq 'crash') {
        die "Intentional scheduler crash for testing\n";
    }
    elsif ($mode eq 'exit') {
        POSIX::_exit(0);
    }
}

1;
