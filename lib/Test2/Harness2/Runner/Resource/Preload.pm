package Test2::Harness2::Runner::Resource::Preload;
use strict;
use warnings;

our $VERSION = '2.000000';

# Predeclare new() so HashBase does not generate one (we define our own below).
sub new;

use Object::HashBase qw/&Test2::Harness2::Runner::Resource <settings <state/;

# §4.7a: model preload-stage availability as a scheduler resource. Unlike a
# bounded resource (JobCount), preload assignment consumes nothing -- this resource
# only GATES preload-directed tasks against the live stage map. It needs a handle
# to live stage state; the owning State builds it with a `state` backref (resources
# normally get only `settings`) and the resource reads stage_is_up / stage_state /
# stage_map straight off it. assign() records nothing bounded; release() is a
# no-op.

sub new {
    my $class = shift;
    my $self = bless {@_}, $class;
    $self->init();
    return $self;
}

sub init {
    my $self = shift;
    # The State backref is required: without it the resource cannot read stage state
    # and must not silently pass every task.
    die "A 'state' backref is required" unless $self->{+STATE};
}

# The ordered preload-stage preference for a task, via the State's resolver so the
# resource and task_stage agree on the list.
sub _preload_list {
    my $self = shift;
    my ($task) = @_;
    return $self->{+STATE}->task_preload_list($task);
}

# §4.7a available() tri-state. Returns:
#   1  -- a listed stage is up (or empty/advisory-miss => falls to default), runnable
#   0  -- no listed stage up yet but >=1 is starting/restarting (coming back) => wait
#  -1  -- every listed stage is permanently gone (absent/down) AND require_preload
#         => skip/fail (an advisory test never returns -1: it falls to default).
sub available {
    my $self = shift;
    my ($task) = @_;

    # A no_preload task forks clean; it is not gated by this resource.
    return 1 if !$task->{use_preload} || $task->{no_preload};

    my $state = $self->{+STATE};
    my $map   = $state->stage_map;

    # No preload stage map at all (a non-staged or no-preload run): nothing to gate.
    return 1 unless $map && keys %$map;

    my $list = $self->_preload_list($task);

    # Empty list => the default stage, always available here (it is the run's base).
    return 1 unless @$list;

    my $waitable = 0;
    for my $stage (@$list) {
        return 1 if $state->stage_is_up($stage);

        # Present in the map but not up yet (starting/restarting): coming back.
        # Absent from the map, or explicitly 'down', is permanently gone.
        next unless $map->{$stage};
        next if $state->stage_state($stage) eq 'down';
        $waitable = 1;
    }

    # Something listed is still coming up: wait for it.
    return 0 if $waitable;

    # Every listed stage is permanently gone. A require_preload test has no
    # presentable stage => skip/fail. An advisory test falls to the default stage.
    return $task->{require_preload} ? -1 : 1;
}

# §4.7a: record the chosen stage on the job (the first available listed stage, or
# the default stage for an advisory miss; nothing for a no_preload task). This
# mirrors State::task_stage's selection so dispatch sends the job to the right
# preload-<stage> channel. assign() MUST NOT mutate internal state.
sub assign {
    my $self = shift;
    my ($task, $res) = @_;

    return if !$task->{use_preload} || $task->{no_preload};

    my $stage = $self->{+STATE}->task_stage($task);
    $res->{record} = {stage => $stage} if defined $stage;

    return;
}

# Preload is not a bounded resource -- assigning a job to a stage consumes nothing,
# so there is nothing to record or free. record() and release() are left as the
# role's no-op defaults (Test2::Harness2::Runner::Resource).

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::Resource::Preload - gate preload-directed tests on stage availability

=head1 DESCRIPTION

A scheduler resource (L<Test2::Harness2::Runner::Resource>) that gates tests on
the availability of the preload stage they were routed to. Stage selection is
decided client-side from each test's preload directives (C<no_preload>,
C<require_preload>, C<preload_list>); this resource maps that selection against
the live stage map and lifecycle to decide whether the test can run now, must
wait for a stage to finish starting, or can never run under the requested stages.

It is not a bounded resource: assigning a job to a stage consumes nothing, so
C<release> is a no-op and there is no limit.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
