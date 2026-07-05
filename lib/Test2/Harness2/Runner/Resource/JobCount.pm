package Test2::Harness2::Runner::Resource::JobCount;
use v5.38;

our $VERSION = '2.000000';

use Object::HashBase qw/&Test2::Harness2::Runner::Resource <settings <job_count <used <free/;
use Time::HiRes qw/time/;
use List::Util qw/min/;

sub job_limiter { 1 }

sub init {
    my $self = shift;
    my $settings = $self->{+SETTINGS};
    $self->{+JOB_COUNT} //= $settings ? $settings->runner->job_count // 1 : 1;
    $self->{+USED} //= {};
    $self->{+FREE} //= [1 .. $self->{+JOB_COUNT}];
}

sub job_limiter_max {
    my $self = shift;
    return $self->{+JOB_COUNT};
}

sub job_limiter_at_max {
    my $self = shift;
    return 0 if @{$self->{+FREE}};
    return 1;
}

sub available {
    my $self = shift;
    my ($task) = @_;

    my $rmin = $self->settings->runner->slots_per_job;
    my $tmin = $task->{min_slots} // 1;
    my $tmax = $task->{max_slots} // $tmin;

    return -1 if $self->{+JOB_COUNT} < $tmin;
    return -1 if $rmin < $tmin;

    my $concurrency = min(grep { $_ } $tmax, $rmin);
    $concurrency ||= 1;

    return 1 if @{$self->{+FREE}} >= $concurrency;
    return 0;
}

sub assign {
    my $self = shift;
    my ($task, $state) = @_;

    my $rmin = $self->settings->runner->slots_per_job;
    my $tmin = $task->{min_slots} // 1;
    my $tmax = $task->{max_slots} // $tmin;
    my $concurrency = min(grep { $_ } $tmax, $rmin);
    $concurrency ||= 1;

    $state->{record} = {
        count => $concurrency,
        file  => $task->{rel_file},
        stamp => time,
    };

    $state->{env_vars}->{T2_HARNESS_MY_JOB_CONCURRENCY} = $concurrency;
}

sub record {
    my $self = shift;
    my ($job_id, $info) = @_;

    my $count = $info->{count};
    my @use = splice @{$self->{+FREE}}, 0, $count;
    $info->{slots} = \@use;

    $self->{+USED}->{$job_id} = $info;
}

sub release {
    my $self = shift;
    my ($job_id) = @_;

    # Could be a free with no used slot.
    my $info = delete $self->{+USED}->{$job_id} or return;
    my $slots = $info->{slots};

    push @{$self->{+FREE}} => @$slots;
}

sub status_data {
    my $self = shift;

    my @rows;

    my $time = time;

    for my $info (sort { $a->{stamp} <=> $b->{stamp} } values %{$self->{+USED}}) {
        my $count = @{$info->{slots} || []};
        push @rows => [$time - $info->{stamp}, $count, $info->{file}];
    }

    push @rows => [undef, scalar(@{$self->{+FREE}}), '** FREE **'];

    return [
        {
            tables => [
                {
                    header => [qw/Runtime Slots Name/],
                    format => ['duration'],
                    rows => \@rows,
                },
            ],
        },
    ],
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::Resource::JobCount - limit the job count (-j)

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness2/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
