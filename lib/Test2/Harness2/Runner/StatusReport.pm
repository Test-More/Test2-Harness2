package Test2::Harness2::Runner::StatusReport;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;

use Object::HashBase qw{
    <state
    <job_pids
    <stage_pids
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::StatusReport - Build the plain-data status snapshot the
runner serves over its socket to the C<status>/C<ps>/C<abort> commands.

=head1 DESCRIPTION

The persistent C<status>, C<ps>, and C<abort> commands used to read the runner's
scheduling state out of C<dispatch.jsonl> (an observe-mode
L<Test2::Harness2::Runner::State>) and each running job's pid out of
C<jobs.jsonl>. Chunk 6.1 retires both files: the runner now answers a C<status>
request over C<runner.socket> with the same information, taken from its live
canonical state.

This object renders that answer: it walks the runner's
L<Test2::Harness2::Runner::State> (the authoritative scheduler state) plus the
runner's in-memory job-pid map (the runner knows each job's pid when it forks it
or when a stage reports the pid of a job it forked) and returns a serializable
hashref the command turns into its tables and its kill list.

=head1 SYNOPSIS

    my $report = Test2::Harness2::Runner::StatusReport->new(
        state      => $runner->state,
        job_pids   => $runner->job_pids,
        stage_pids => $runner->stage_peer_pids,
    );

    my $data = $report->build;
    # {
    #   runs           => [ { run_id => ..., pending => [...] }, ... ],
    #   running        => [ { job_id, run_id, pid, rel_file, is_try, conflicts }, ... ],
    #   stage_pids      => { default => $pid, ... },   # connected stages' real pids
    #   stage_lifecycle => { default => { state => 'up', stamp => T }, ... },
    #   reload_state    => { ... },                    # state eq 'up' == schedulable
    # }

=head1 PUBLIC METHODS

=over 4

=item $state = $report->state

The runner's canonical L<Test2::Harness2::Runner::State>.

=item $hash = $report->job_pids

The runner's C<< { job_id =E<gt> pid } >> map.

=item $hash = $report->stage_pids

The C<< { stage =E<gt> pid } >> map of each connected preload stage's real pid,
read from its peer connection. A down/restarting stage has no connection and so
no entry.

=item $data = $report->build

Build and return the serializable status hashref described above.

=back

=cut

sub init ($self) {
    croak "'state' is a required attribute" unless $self->{+STATE};
    $self->{+JOB_PIDS}   //= {};
    $self->{+STAGE_PIDS} //= {};
    return;
}

sub build ($self) {
    my $state = $self->{+STATE};

    return {
        runs            => $self->_runs,
        running         => $self->_running,
        # §6.8: the per-stage lifecycle ({state, stamp}) is the single
        # source of stage scheduling state; `state eq 'up'` is the dispatch gate. The
        # State stores no pid; a connected stage's real pid is reported separately in
        # stage_pids, sourced from its peer connection.
        stage_pids      => {%{$self->{+STAGE_PIDS}}},
        stage_lifecycle => {%{$state->stage_lifecycle // {}}},
        reload_state    => $state->reload_state // {},
    };
}

=head1 PRIVATE METHODS

=over 4

=item $arrayref = $self->_runs

Build the per-run pending-task lists (the active run plus any pending runs),
flattening the nested pending-task buckets into a flat list of task records.

=item $arrayref = $self->_running

Build the running-task list, attaching each job's pid from the runner's job-pid
map.

=item @tasks = $self->_flatten_pending($pending_for_run)

Flatten one run's nested pending-task structure into its leaf task records.

=back

=cut

sub _runs ($self) {
    my $state   = $self->{+STATE};
    my $pending = $state->pending_tasks // {};

    my @runs;
    for my $run ($state->run, @{$state->pending_runs // []}) {
        next unless $run;
        my $run_id = $run->{run_id} or next;

        push @runs => {
            run_id  => $run_id,
            pending => [$self->_flatten_pending($pending->{$run_id} // {})],
        };
    }

    return \@runs;
}

sub _flatten_pending ($self, $pending) {
    my @tasks;
    my @check = ($pending);
    while (my $it = shift @check) {
        my $ref = ref($it);

        if ($ref eq 'ARRAY') {
            push @check => @$it;
            next;
        }

        if ($ref eq 'HASH') {
            if ($it->{job_id}) {
                push @tasks => {
                    job_id    => $it->{job_id},
                    is_try    => $it->{is_try} // $it->{job_try} // 0,
                    rel_file  => $it->{rel_file},
                    conflicts => [@{$it->{conflicts} // []}],
                };
                next;
            }

            push @check => values %$it;
            next;
        }
    }

    return @tasks;
}

sub _running ($self) {
    my $state    = $self->{+STATE};
    my $job_pids = $self->{+JOB_PIDS};
    my $running  = $state->running_tasks // {};

    my @out;
    for my $task (values %$running) {
        push @out => {
            job_id    => $task->{job_id},
            run_id    => $task->{run_id},
            pid       => $job_pids->{$task->{job_id}},
            rel_file  => $task->{rel_file},
            is_try    => $task->{is_try} // $task->{job_try} // 0,
            conflicts => [@{$task->{conflicts} // []}],
        };
    }

    return \@out;
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
