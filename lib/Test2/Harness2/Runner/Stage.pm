package Test2::Harness2::Runner::Stage;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;

use Test2::Harness2::Runner::Run();
use Test2::Harness2::Runner::Client();

use Test2::Harness2::Util::HashBase qw{
    <workdir
    <name
    +client
    +pending
    +runs
    +current_run
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::Stage - In-stage dispatch delegate for a transient
preload-stage service.

=head1 DESCRIPTION

In the transient runner each global preload stage runs as a service that binds
C<< preload-E<lt>stageE<gt>.socket >> and forks matching tests from its preloaded
interpreter. This object stands in for the runner's
L<Test2::Harness2::Runner::State> inside such a stage child: the stage no longer
polls C<dispatch.jsonl> for work, so it does not need the full scheduler state.

The stage's service loop hands each dispatched C<run_task> request to
C<enqueue_task>; the stage's run loop pops them via C<next_task> (the same
method name the runner's State exposes, so the shared C<run_job> code is
unchanged) and forks the job. When a job finishes the stage reports the outcome
back to the runner over C<runner.socket> via C<stop_task> / C<retry_task> /
C<halt_run>, so the runner's canonical in-process state stays authoritative for
scheduling without a shared file.

=head1 PUBLIC METHODS

=over 4

=item $stage->enqueue_task($task, $run_item)

Record a dispatched task (and the run definition it belongs to) for the stage to
fork. Called from the service request handler.

=item $task = $stage->next_task($stage_name)

Pop the next pending task for the stage, or C<undef>. Matches the runner State
API used by C<run_job>.

=item $run = $stage->run

The L<Test2::Harness2::Runner::Run> for the most recently dispatched run (built
from the dispatched run item), or C<undef> before any dispatch.

=item $stage->stop_task($job_id)

Report a finished job to the runner so it releases the slot/resources.

=item $stage->retry_task($job_id)

Report a finished-but-should-retry job to the runner.

=item $stage->halt_run($run_id)

Ask the runner to halt the run (e.g. a bail-out under --abort-on-bail).

=item $stage->stage_ready / $stage->stage_down

No-ops: stage readiness is signalled to the runner by the socket accepting a
connection, not by a state action. Present so the shared C<run_stage> code can
call them uniformly.

=back

=cut

sub init ($self) {
    croak "'workdir' is a required attribute" unless defined $self->{+WORKDIR};
    croak "'name' is a required attribute"    unless defined $self->{+NAME};
    $self->{+PENDING} //= [];
    $self->{+RUNS}    //= {};
    return;
}

sub client ($self) {
    return $self->{+CLIENT} //= Test2::Harness2::Runner::Client->new(workdir => $self->{+WORKDIR});
}

sub enqueue_task ($self, $task, $run_item) {
    my $run_id = $task->{run_id} // croak "Dispatched task has no run_id";

    my $run = $self->{+RUNS}{$run_id} //= Test2::Harness2::Runner::Run->new(
        %$run_item,
        workdir => $self->{+WORKDIR},
    );

    push @{$self->{+PENDING}} => {task => $task, run => $run};
    return;
}

sub next_task ($self, $stage = undef) {
    my $next = shift @{$self->{+PENDING}} or return undef;
    $self->{+CURRENT_RUN} = $next->{run};
    return $next->{task};
}

sub run ($self) { return $self->{+CURRENT_RUN} }

sub stop_task ($self, $job_id) {
    $self->client->stop_task($job_id);
    return;
}

sub retry_task ($self, $job_id) {
    $self->client->retry_task($job_id);
    return;
}

sub halt_run ($self, $run_id) {
    $self->client->halt_run($run_id);
    return;
}

sub stage_ready ($self, @) { return }
sub stage_down  ($self, @) { return }

# The stage never decides it is "done" on its own: it serves dispatches until the
# runner stops it (a stop request or SIGTERM at run shutdown). Returning false
# keeps the stage's run loop waiting for more work.
sub done ($self, @) { return 0 }

# Forward a reload/monitor notification to the runner so its reload state (used for
# diagnostics) stays current; the stage itself keeps no scheduler state.
sub reload ($self, $stage, $data) {
    $self->client->reload($stage, $data);
    return;
}

1;

__END__

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

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
