package Test2::Harness2::Scheduler;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak/;

use Test2::Harness2::Util::HashBase qw{
    <runs
    <resources
    <plugins
    <workspace
    <_job_index
};

sub init {
    my $self = shift;

    $self->{+RUNS}       //= [];
    $self->{+RESOURCES}  //= [];
    $self->{+PLUGINS}    //= [];
    $self->{+_JOB_INDEX} //= {};

    return;
}

sub queue_run {
    my ($self, $run) = @_;

    croak "run is required" unless $run;

    push @{$self->{+RUNS}}, $run;

    for my $job (@{$run->jobs}) {
        $self->{+_JOB_INDEX}{$job->uuid} = $job;
    }

    for my $plugin (@{$self->{+PLUGINS}}) {
        $plugin->on_run_queued($run);
    }

    return;
}

sub add_tests_to_run {
    my ($self, $run_uuid, $test_files) = @_;

    my $run = $self->find_run($run_uuid)
        or croak "No run found with uuid '$run_uuid'";

    my $old_count = scalar @{$run->jobs};

    $run->add_test_files($test_files);

    my $jobs = $run->jobs;
    for my $i ($old_count .. $#$jobs) {
        $self->{+_JOB_INDEX}{$jobs->[$i]->uuid} = $jobs->[$i];
    }

    return;
}

sub next_job {
    my $self = shift;

    for my $run (@{$self->{+RUNS}}) {
        my $pending = $run->pending_jobs;

        JOB: for my $job (@$pending) {
            my @applicable;

            for my $resource (@{$self->{+RESOURCES}}) {
                next unless $resource->applicable($job);
                push @applicable, $resource;
            }

            for my $resource (@applicable) {
                my $avail = $resource->available($job);

                if ($avail == -1) {
                    # Broken resource: mark job as failed
                    $job->set_status('complete');
                    $job->set_result(passed => 0, exit_code => -1);
                    next JOB;
                }

                if ($avail == 0) {
                    # Temporarily unavailable: skip this job
                    next JOB;
                }
            }

            # All applicable resources available
            for my $resource (@applicable) {
                $resource->assign($job);
            }

            $job->set_status('running');

            for my $plugin (@{$self->{+PLUGINS}}) {
                $plugin->on_job_queued($job);
            }

            return $job;
        }
    }

    return undef;
}

sub job_complete {
    my ($self, $job, %result) = @_;

    $job->set_result(passed => $result{passed}, exit_code => $result{exit_code});
    $job->set_status('complete');
    $job->set_log_file($result{log_file}) if defined $result{log_file};

    for my $resource (@{$self->{+RESOURCES}}) {
        next unless $resource->applicable($job);
        $resource->release($job);
    }

    for my $plugin (@{$self->{+PLUGINS}}) {
        $plugin->on_job_complete($job);
    }

    # Check if the job's run is now complete
    my $run_id = $job->run_id;
    for my $run (@{$self->{+RUNS}}) {
        if ($run->uuid eq $run_id) {
            if ($run->is_complete) {
                for my $plugin (@{$self->{+PLUGINS}}) {
                    $plugin->on_run_complete($run);
                }
            }
            last;
        }
    }

    return;
}

sub job_params {
    my ($self, $uuid) = @_;

    my $job = $self->find_job($uuid)
        or croak "No job found with uuid '$uuid'";

    my $run;
    my $run_id = $job->run_id;
    for my $r (@{$self->{+RUNS}}) {
        if ($r->uuid eq $run_id) {
            $run = $r;
            last;
        }
    }

    return {
        test_file     => $job->test_file->file,
        uuid          => $job->uuid,
        run_id        => $job->run_id,
        log_dir       => $self->{+WORKSPACE} ? $self->{+WORKSPACE}->run_log_dir($job->run_id) : undef,
        test_settings => $run                ? $run->test_settings                            : undef,
    };
}

sub all_complete {
    my $self = shift;

    my $runs = $self->{+RUNS};
    return 0 unless @$runs;

    for my $run (@$runs) {
        return 0 unless $run->is_complete;
    }

    return 1;
}

sub find_job {
    my ($self, $uuid) = @_;
    return $self->{+_JOB_INDEX}{$uuid};
}

sub find_run {
    my ($self, $run_uuid) = @_;

    for my $run (@{$self->{+RUNS}}) {
        return $run if $run->uuid eq $run_uuid;
    }

    return undef;
}

sub queue_rerun {
    my ($self, $job_uuid) = @_;

    my $job = $self->find_job($job_uuid)
        or croak "No job found with uuid '$job_uuid'";

    my $old_uuid = $job->uuid;

    $job->retry();

    # Remove old index entry, add new one
    delete $self->{+_JOB_INDEX}{$old_uuid};
    $self->{+_JOB_INDEX}{$job->uuid} = $job;

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Scheduler - Manages runs, resources, and job assignment

=head1 SYNOPSIS

    use Test2::Harness2::Scheduler;

    my $scheduler = Test2::Harness2::Scheduler->new(
        resources => [$job_count_resource],
        plugins   => [$my_plugin],
        workspace => $workspace,
    );

    $scheduler->queue_run($run);

    while (!$scheduler->all_complete) {
        if (my $job = $scheduler->next_job) {
            # dispatch job...
        }
    }

=head1 DESCRIPTION

Local scheduler that manages Run objects, checks resource availability, and
assigns jobs. This is a plain Perl object, not an IPC service. The IPC
wrapping is handled by a separate layer.

=head1 ATTRIBUTES

=over 4

=item runs

Arrayref of L<Test2::Harness2::Run> objects.

=item resources

Arrayref of instantiated L<Test2::Harness2::Resource> objects.

=item plugins

Arrayref of instantiated L<Test2::Harness2::Plugin> objects.

=item workspace

Optional L<Test2::Harness2::Workspace> object for log directory resolution.

=back

=head1 METHODS

=over 4

=item $scheduler->queue_run($run)

Add a Run to the scheduler, index its jobs, and fire plugin C<on_run_queued>
hooks.

=item $scheduler->add_tests_to_run($run_uuid, \@test_files)

Find a run by UUID, add test files to it, and index the new jobs.

=item $job = $scheduler->next_job()

Find and return the next dispatchable job, or C<undef> if none are ready.
Checks resource availability and fires plugin C<on_job_queued> hooks.

=item $scheduler->job_complete($job, %result)

Mark a job complete with the given result (C<passed>, C<exit_code>,
optional C<log_file>). Releases resources and fires plugin hooks.

=item $params = $scheduler->job_params($uuid)

Return a hashref of parameters for launching the job identified by C<$uuid>.

=item $bool = $scheduler->all_complete()

True when all queued runs have completed.

=item $job = $scheduler->find_job($uuid)

Look up a job by UUID.

=item $run = $scheduler->find_run($run_uuid)

Look up a run by UUID.

=item $scheduler->queue_rerun($job_uuid)

Retry the job identified by C<$job_uuid>, re-indexing under the new UUID.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
