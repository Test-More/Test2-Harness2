package SchedulerKillerResource;
use strict;
use warnings;

use Object::HashBase qw/&Test2::Harness2::Runner::Resource/;

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
        # The scheduler fails fast: a throw out of tick() is a real in-process
        # bug and is no longer retried. A resource that wants to tolerate a
        # transient error must absorb it inside its own tick(). Simulate that
        # here: hit a transient error a few times but swallow it ourselves so the
        # run completes instead of aborting.
        $self->{_error_count} //= 0;
        if ($self->{_error_count}++ < 2) {
            my $ok = eval {
                die "Transient scheduler error for testing\n";
                1;
            };
            warn "SchedulerKillerResource absorbed transient error: $@" unless $ok;
        }
        # After 2 errors, stop hitting the transient error entirely.
    }
}

1;
