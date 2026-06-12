package Test2::Harness2;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak/;
use POSIX ();
use Time::HiRes qw/sleep time/;

use Test2::Harness2::Workspace;
use Test2::Harness2::Scheduler;
use Test2::Harness2::Resource::JobCount;
use Test2::Harness2::Run;
use Test2::Harness2::MiniHarness;
use Test2::Harness2::MiniHarness::Result;

use IPC::Manager::Util qw/clone_io/;

use Test2::Harness2::Util::HashBase qw{
    <workspace
    <scheduler
    <job_count
    <resources
    <plugins
    <includes
    <env_vars
    <switches
    <test_settings
    <preloads
    <_preload_manager
    ipcm_info
    <_ipcm
    <_service_handle
    <heartbeat_interval
    +shutdown_requested
    +emergency_shutdown

    <name
    <orig_io
    <_pending_test_files
    <_result_file
    _pid
};

use Role::Tiny::With;
with 'IPC::Manager::Role::Service';

sub run {
    my ($class_or_self, %params) = @_;

    # Class method: convenience API
    if (!ref($class_or_self)) {
        my $harness = $class_or_self->new(%params);
        return $harness->run_tests(%params);
    }

    # Instance method: Role::Service event loop
    return $class_or_self->IPC::Manager::Role::Service::run();
}

sub init {
    my $self = shift;

    $self->{+JOB_COUNT}          //= 1;
    $self->{+RESOURCES}          //= [];
    $self->{+PLUGINS}            //= [];
    $self->{+INCLUDES}           //= [];
    $self->{+ENV_VARS}           //= {};
    $self->{+SWITCHES}           //= [];
    $self->{+HEARTBEAT_INTERVAL} //= 30;
    $self->{+SHUTDOWN_REQUESTED} //= 0;
    $self->{+EMERGENCY_SHUTDOWN} //= 0;
    $self->{+NAME}               //= 'harness';
    $self->{+_PID}               //= $$;

    # Always spawn IPC bus if info not provided
    unless ($self->{+IPCM_INFO}) {
        require IPC::Manager;
        my $ipcm = IPC::Manager::ipcm_spawn();
        $self->{+_IPCM}     = $ipcm;
        $self->{+IPCM_INFO} = $ipcm->info;
    }

    # Auto-create workspace if not provided
    $self->{+WORKSPACE} //= Test2::Harness2::Workspace->new(cleanup => 1);

    # Initialize preload manager if preloads are provided
    if ($self->{+PRELOADS} && @{$self->{+PRELOADS}}) {
        require Test2::Harness2::Preload::Manager;
        $self->{+_PRELOAD_MANAGER} = Test2::Harness2::Preload::Manager->new(
            preloads  => $self->{+PRELOADS},
            workspace => $self->{+WORKSPACE},
            includes  => $self->{+INCLUDES},
        );
        $self->{+_PRELOAD_MANAGER}->start();
    }

    # Build resource list: always include JobCount, plus any extras
    my @all_resources = (
        Test2::Harness2::Resource::JobCount->new(job_count => $self->{+JOB_COUNT}),
        @{$self->{+RESOURCES}},
    );

    # Auto-create scheduler if not provided
    $self->{+SCHEDULER} //= Test2::Harness2::Scheduler->new(
        resources => \@all_resources,
        plugins   => $self->{+PLUGINS},
        workspace => $self->{+WORKSPACE},
    );

    return;
}

# ============================================================
# Role::Service required methods
# ============================================================

sub pid     { $_[0]->{+_PID} // $$ }
sub set_pid { $_[0]->{+_PID} = $_[1] }

sub watch_pids { [$$] }

sub interval { $_[0]->{+HEARTBEAT_INTERVAL} // 30 }

sub handle_request {
    my ($self, $req, $msg) = @_;
    my $request = $req->{request}  // $req;
    my $type    = $request->{type} // '';

    if ($type eq 'settings_request') {
        return {settings => $self->{+TEST_SETTINGS}};
    }
    elsif ($type eq 'job_params_request') {
        return $self->{+SCHEDULER}->job_params($request->{uuid});
    }
    elsif ($type eq 'get_results') {
        $self->terminate(0);
        return {result_file => $self->{+_RESULT_FILE}};
    }

    return {error => "unknown request type: $type"};
}

sub run_on_start {
    my $self = shift;

    # Detach the Spawn guard in the child so it won't shut down the
    # IPC bus when the child exits.
    if ($self->{+_IPCM}) {
        $self->{+_IPCM}->{guard} = 0;
    }

    my $test_files = $self->{+_PENDING_TEST_FILES}
        or return;

    # Create and queue the run
    my $ts  = $self->{+TEST_SETTINGS};
    my $run = Test2::Harness2::Run->new(
        test_files => $test_files,
        ($ts ? (test_settings => $ts) : ()),
    );

    my $scheduler = $self->{+SCHEDULER};
    $scheduler->queue_run($run);

    my @results;

    # Main execution loop
    while (1) {
        if (my $job = $scheduler->next_job()) {
            my $result = $self->_execute_job($job);
            push @results, $result;

            $scheduler->job_complete(
                $job,
                passed    => $result->passed,
                exit_code => $result->exit_code,
                log_file  => $result->log_file,
            );
        }
        elsif ($scheduler->all_complete) {
            last;
        }
        else {
            # Resources may be busy; sleep and retry
            sleep(0.1);
        }
    }

    # Write results to temp file
    my $summary = $self->_summarize_results(\@results);

    my @serial_results;
    for my $r (@results) {
        push @serial_results, {
            passed    => $r->passed ? 1 : 0,
            exit_code => $r->exit_code,
            log_file  => $r->log_file,
            uuid      => $r->uuid,
        };
    }

    my $data = {
        passed  => $summary->{passed},
        total   => $summary->{total},
        failed  => $summary->{failed},
        results => \@serial_results,
    };

    require JSON::PP;
    my $ok = eval {
        open my $fh, '>', $self->{+_RESULT_FILE} or die "Cannot write $self->{+_RESULT_FILE}: $!";
        print $fh JSON::PP::encode_json($data);
        close $fh;
        1;
    };
    my $err = $@;
    warn "Failed to write results: $err" unless $ok;
}

# ============================================================
# Public API
# ============================================================

sub shutdown_requested { $_[0]->{+SHUTDOWN_REQUESTED} }
sub emergency_shutdown { $_[0]->{+EMERGENCY_SHUTDOWN} }

sub request_shutdown {
    my $self = shift;
    $self->{+SHUTDOWN_REQUESTED} = 1;

    # If running as a service, signal termination
    $self->terminate(0) if $self->is_terminated || defined $self->{_TERMINATED};

    return;
}

sub _handle_scheduler_death {
    my ($self, $is_orderly) = @_;

    # Orderly shutdown (shutdown_requested) — expected, do nothing
    return if $is_orderly;

    # Unexpected death — trigger emergency shutdown
    $self->{+EMERGENCY_SHUTDOWN} = 1;

    # If running as a service, signal termination
    $self->terminate(255);

    return;
}

sub run_tests {
    my ($self, %params) = @_;

    my $test_files = $params{test_files}
        or croak "test_files is required";

    croak "test_files must be an arrayref" unless ref($test_files) eq 'ARRAY';

    return $self->_run_tests_ipc(%params);
}

sub _run_tests_ipc {
    my ($self, %params) = @_;

    my $test_files = $params{test_files};
    my $ipcm_info  = $self->{+IPCM_INFO}
        or croak "ipcm_info is not available";

    require IPC::Manager;
    require File::Temp;
    require JSON::PP;

    # Temp file for passing results from child back to parent
    my $result_fh   = File::Temp->new(UNLINK => 1, SUFFIX => '.json');
    my $result_file = $result_fh->filename;
    close $result_fh;

    # Store state for the service child
    $self->{+_PENDING_TEST_FILES} = $test_files;
    $self->{+_RESULT_FILE}        = $result_file;

    # Clone IO before fork
    $self->{+ORIG_IO} //= {
        stderr => clone_io('>&', \*STDERR),
        stdout => clone_io('>&', \*STDOUT),
        stdin  => clone_io('<&', \*STDIN),
    };

    $self->pre_fork_hook();

    my $pid = fork // die "Could not fork: $!";

    if ($pid) {
        # === PARENT ===
        my $handle = $self->handle(name => "harness_parent_$$");

        # Wait for service to be ready
        my $timeout = 10;
        my $start   = time;
        until ($handle->ready) {
            last if time - $start > $timeout;
            sleep 0.025;
        }
        croak "Timeout waiting for harness service to start after ${timeout}s"
            unless $handle->ready;

        $self->{+_SERVICE_HANDLE} = $handle;

        # Ask the service for results (blocks until test execution is complete)
        $handle->sync_request('harness', {type => 'get_results'});

        # Read and decode the results from the temp file
        my $data;
        my $ok = eval {
            open my $fh, '<', $result_file or die "Cannot read $result_file: $!";
            local $/;
            my $json = <$fh>;
            close $fh;
            $data = JSON::PP::decode_json($json);
            1;
        };
        my $err = $@;

        croak "Failed to read IPC results: $err" unless $ok && $data;

        # Reconstruct MiniHarness::Result objects from serialized data
        my @results;
        for my $r (@{$data->{results}}) {
            push @results, Test2::Harness2::MiniHarness::Result->new(%$r);
        }

        return {
            passed  => $data->{passed},
            total   => $data->{total},
            failed  => $data->{failed},
            results => \@results,
        };
    }

    # === CHILD (SERVICE) ===
    $self->set_pid($$);
    $0 = "$0 harness";

    # Prevent workspace cleanup in child
    $self->{+WORKSPACE}->{cleanup} = 0 if $self->{+WORKSPACE};

    my $exit = $self->run();
    exit($exit // 0);
}

sub service_handle {
    my $self = shift;
    return $self->{+_SERVICE_HANDLE};
}

sub _execute_job {
    my ($self, $job) = @_;

    my $scheduler = $self->{+SCHEDULER};
    my $params    = $scheduler->job_params($job->uuid);

    # Ensure run log dir exists via workspace
    my $log_dir = $params->{log_dir};
    unless ($log_dir) {
        $log_dir = $self->{+WORKSPACE}->run_log_dir($job->run_id);
    }

    # Try launching through the preload manager if available
    if (my $pm = $self->{+_PRELOAD_MANAGER}) {
        my $result_hash = $pm->launch_test(
            test_file => $job->test_file->file,
            log_dir   => $log_dir,
            uuid      => $job->uuid,
            includes  => $self->{+INCLUDES},
            env       => $self->{+ENV_VARS},
            switches  => $self->{+SWITCHES},
        );
        if ($result_hash) {
            # Convert to MiniHarness::Result
            return Test2::Harness2::MiniHarness::Result->new(%$result_hash);
        }
    }

    # Fall through to direct MiniHarness if preload not available
    my $result = Test2::Harness2::MiniHarness->run(
        test_file => $job->test_file->file,
        log_dir   => $log_dir,
        uuid      => $job->uuid,
        includes  => $self->{+INCLUDES},
        env       => $self->{+ENV_VARS},
        switches  => $self->{+SWITCHES},
    );

    return $result;
}

sub _summarize_results {
    my ($self, $results) = @_;

    my $total      = scalar @$results;
    my $failed     = grep { !$_->passed } @$results;
    my $all_passed = $failed ? 0 : 1;

    return {
        passed  => $all_passed,
        total   => $total,
        failed  => $failed,
        results => $results,
    };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2 - Test harness for Test2

=head1 SYNOPSIS

    use Test2::Harness2;

    # Convenience class method
    my $result = Test2::Harness2->run(
        test_files => \@test_file_objects,
        job_count  => 4,
        includes   => ['lib'],
    );

    # Or construct and run explicitly
    my $harness = Test2::Harness2->new(
        job_count => 4,
        includes  => ['lib'],
    );

    my $result = $harness->run_tests(
        test_files => \@test_file_objects,
    );

    print "All passed!\n" if $result->{passed};

=head1 DESCRIPTION

The main harness class for L<Test2::Harness2>. Creates a Workspace, creates a
Scheduler with resources, then loops: get next job from scheduler, execute via
MiniHarness, report complete, repeat until done.

Test execution always runs through IPC. The harness implements
L<IPC::Manager::Role::Service>, forking a child process to run the test loop
while the parent communicates with it via IPC.

=head1 CLASS METHODS

=over 4

=item $result = Test2::Harness2->run(%params)

Convenience method. Creates a new instance with C<%params> and immediately
calls C<run_tests(%params)>.

=back

=head1 ATTRIBUTES

=over 4

=item workspace

L<Test2::Harness2::Workspace> object. Auto-created if not provided.

=item scheduler

L<Test2::Harness2::Scheduler> object. Auto-created if not provided.

=item job_count

Maximum number of concurrent jobs (default 1). Used to create a
L<Test2::Harness2::Resource::JobCount> resource.

=item resources

Optional arrayref of extra L<Test2::Harness2::Resource> objects.

=item plugins

Optional arrayref of L<Test2::Harness2::Plugin> objects.

=item includes

Optional arrayref of C<-I> include paths.

=item env_vars

Optional hashref of environment variables.

=item switches

Optional arrayref of perl switches.

=item test_settings

Optional L<Test2::Harness2::TestSettings> object.

=item heartbeat_interval

Interval in seconds for the IPC service heartbeat (default 30).

=back

=head1 METHODS

=over 4

=item $result = $harness->run_tests(test_files => \@files)

Run the given test files. Returns a hashref with keys C<passed> (boolean),
C<total> (count), C<failed> (count), and C<results> (arrayref of
L<Test2::Harness2::MiniHarness::Result> objects).

=item $harness->request_shutdown()

Request an orderly shutdown. Broadcasts a shutdown message via IPC.

=item $harness->shutdown_requested()

Returns true if shutdown has been requested.

=item $harness->emergency_shutdown()

Returns true if an emergency shutdown is in progress.

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
