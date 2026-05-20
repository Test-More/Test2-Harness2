package Test2::Harness2::Role::Launcher;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use POSIX qw/:sys_wait_h/;
use Time::HiRes qw/sleep time/;

use Test2::Harness2::Util::JSON qw/decode_json/;

use Role::Tiny;

with 'Test2::Harness2::Role::Service';

requires 'start_process';

sub handle       { $_[0]->{handle} }
sub launcher_id  { $_[0]->{launcher_id} }
sub scheduler_pid {
    my $self = shift;
    $self->{scheduler_pid} = $_[0] if @_;
    return $self->{scheduler_pid};
}
sub stopping     {
    my $self = shift;
    $self->{stopping} = $_[0] if @_;
    return $self->{stopping};
}
sub children     {
    my $self = shift;
    $self->{_launcher_children} //= {};
    return $self->{_launcher_children};
}

sub should_stop {
    my $self = shift;
    return 1 if $self->stopping && !keys %{$self->children};
    return 0;
}

sub tick {
    my $self = shift;

    my $reaped = $self->reap_children;

    return $reaped if $self->stopping;

    my $started = $self->_dispatch_pending;

    return $reaped + $started;
}

sub _dispatch_pending {
    my $self = shift;
    my $h    = $self->handle or croak "launcher has no handle";
    my $lid  = $self->launcher_id;
    croak "launcher_id is required" unless defined $lid;

    my $dbh   = $h->dbh;
    my $rows  = $dbh->selectall_arrayref(
        "SELECT launches.launch_id, launches.job_id, jobs.spec
           FROM launches
           JOIN jobs ON jobs.job_id = launches.job_id
          WHERE launches.launcher_id = ?
            AND launches.started IS NULL
       ORDER BY launches.launch_id",
        {Slice => {}},
        $lid,
    );

    my $count = 0;
    for my $row (@$rows) {
        $self->_start_one($row);
        $count++;
    }
    return $count;
}

sub _start_one {
    my ($self, $row) = @_;

    my $spec = $self->_decode_spec($row->{spec});

    my $pid = $self->start_process($spec);
    croak "start_process returned no pid" unless $pid;

    my $now = time();
    $self->handle->dbh->do(
        "UPDATE launches SET started = ? WHERE launch_id = ?",
        undef, $now, $row->{launch_id},
    );

    $self->children->{$pid} = {
        launch_id => $row->{launch_id},
        job_id    => $row->{job_id},
        started   => $now,
    };
    return $pid;
}

sub _decode_spec {
    my ($self, $raw) = @_;
    return {} unless defined $raw && length $raw;
    my $decoded = eval { decode_json($raw) };
    return $decoded if ref($decoded) eq 'HASH';
    return {};
}

sub reap_children {
    my $self = shift;

    my $kids = $self->children;
    my $reaped = 0;

    while (my $pid = waitpid(-1, WNOHANG)) {
        last if $pid <= 0;
        my $status = $?;
        my $info   = delete $kids->{$pid};
        next unless $info;
        $reaped++;
        $self->_on_child_exit($pid, $status, $info);
    }

    return $reaped;
}

sub _on_child_exit {
    my ($self, $pid, $status, $info) = @_;

    if (my $sched = $self->scheduler_pid) {
        kill 'USR1', $sched;
    }
    return;
}

sub on_stop {
    my $self = shift;

    my $deadline = time() + 30;
    while (keys %{$self->children}) {
        $self->reap_children;
        last if !keys %{$self->children};
        last if time() >= $deadline;
        sleep 0.05;
    }
    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Role::Launcher - Role for launcher services. Polls
the C<launches> table for unstarted rows targeting this launcher,
starts the requested processes, marks them started, and reaps the
collector children when they exit.

=head1 DESCRIPTION

Consumes L<Test2::Harness2::Role::Service>. Launchers inherit the
poll loop + C<SIGUSR1>-interruptible backoff from there; this role
fills in the launcher-specific C<tick> behavior:

=over 4

=item *

Reaps any collector children that have exited since the last tick
(C<waitpid -1 WNOHANG>). If C<scheduler_pid> is set, a C<SIGUSR1>
is sent to the scheduler on each completion so it picks up the new
state without waiting out its backoff.

=item *

If the launcher is not stopping, polls the C<launches> table for
rows with C<launcher_id = $self->launcher_id> and C<started IS NULL>,
joined to C<jobs.spec>. For each row it calls
L</start_process>(\%spec) (provided by the subclass), records the
pid, and updates C<launches.started>.

=item *

Returns the total amount of work performed (reaped + started) so
L<Test2::Harness2::Role::Service>'s loop can reset or extend its
backoff appropriately.

=back

On stop the launcher refuses new launches and waits up to 30s for
already-running children to exit before returning.

=head1 ATTRIBUTES

These live directly on C<$self->{...}>; consuming classes are
expected to use L<Object::HashBase> attributes with the same names.

=over 4

=item handle

The L<Test2::Harness2> handle. Used for the DBI access this role
performs.

=item launcher_id

The C<launchers.launcher_id> this launcher polls for.

=item scheduler_pid

Optional. When set, a C<SIGUSR1> is sent to this pid on each child
completion.

=item stopping

When set, the launcher refuses new launches and exits as soon as
all in-flight children have been reaped.

=back

=head1 REQUIRED METHODS

=over 4

=item $pid = $launcher->start_process(\%spec)

Spawn the process described by C<%spec>. The exact contents are
launcher-specific, but every implementation accepts at least
C<exec =E<gt> [@argv]>. Return the child pid. The role updates
C<launches.started> after this returns successfully.

=back

=head1 PROVIDED METHODS

=over 4

=item $count = $launcher->tick

One iteration of the launcher loop: reap completed children, then
(unless stopping) start any pending launches. Returns the amount of
work done.

=item $bool = $launcher->should_stop

True when C<stopping> is set and no children remain.

=item $count = $launcher->reap_children

Non-blocking C<waitpid> sweep. Returns the number of children
reaped.

=item $launcher->on_stop

Drain any in-flight children, then return. Has a 30-second deadline.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
