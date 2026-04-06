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
    $self->{_task_started}++;
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
    elsif ($mode eq 'recover') {
        # Throw a few times then stop, simulating a transient error
        $self->{_error_count} //= 0;
        if ($self->{_error_count}++ < 2) {
            die "Transient scheduler error for testing\n";
        }
        # After 2 errors, stop throwing — scheduler should recover
    }
}

1;
