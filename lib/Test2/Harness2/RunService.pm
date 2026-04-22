package Test2::Harness2::RunService;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Path qw/make_path/;
use Scalar::Util qw/blessed/;
use Time::HiRes qw/time/;
use Test2::Util::UUID qw/gen_uuid/;
use POSIX ();

use IPC::Manager::Service::Handle;
use Test2::Harness2::Collector;
use Test2::Harness2::Role::ResourceServiceHost;
use Test2::Harness2::Role::Service;
use Test2::Harness2::Util::EventEmitter;
use Test2::Harness2::Util::JSON qw/write_json_file_atomic/;

use Object::HashBase qw{
    <workdir
    <logdir
    <name
    <log_name
    <run_id
    <job_id
    <snapshot_file
    <kill_timeout
    <ipcm_info
    <parent_pids
    <harness_name
    <loggers
    <test_loggers
    +run
    state
    <resource_services
    +test_jobs
    +emitter
    watch_pids
    own_pgroup
};

# Public accessor for the Run object -- named run_obj rather than 'run'
# to avoid shadowing IPC::Manager::Role::Service's run() loop method.
sub run_obj { $_[0]->{+RUN} }

# Reservation check on the role uses the log file name, not the bus
# name (which is suffixed with the run_id to guarantee uniqueness
# across runs on the shared IPC bus).
sub service_host_log_name { $_[0]->{+LOG_NAME} }

# Resource-service log files live under the harness's $logdir, not the
# bare $workdir.
sub service_host_logdir { $_[0]->{+LOGDIR} }

use Role::Tiny::With;
with 'Test2::Harness2::Role::Service', 'Test2::Harness2::Role::ResourceServiceHost';

# Role::ResourceServiceHost scope hooks: the run service is the
# run-scoped host for its Run, so its own name is reserved in per-run
# scope for this specific run. A global-scoped resource never sees this
# reservation, and other runs never collide with ours.
sub service_host_scope { 'run' }
sub service_host_run   { $_[0]->{+RUN} }

# The run service acts as a subreaper for the run's subtree (tests it
# launches and resource services scoped to this run).
sub become_sub_reaper { 1 }

sub init {
    my $self = shift;

    my $wd = $self->{+WORKDIR} // croak "'workdir' is a required attribute";
    croak "workdir '$wd' does not exist or is not a directory" unless -d $wd;

    my $run = $self->{+RUN} // croak "'run' is a required attribute";
    croak "'run' must be a Test2::Harness2::Run, got " . (blessed($run) || ref($run) || '(scalar)')
        unless blessed($run) && $run->isa('Test2::Harness2::Run');

    $self->{+RUN_ID} //= $run->run_id;

    # logdir defaults to $workdir/logs/ -- mirroring the harness's own
    # default. Callers that pass their own logdir (typically the
    # harness handing through $self->{+LOGDIR}) get that path verbatim.
    $self->{+LOGDIR} //= "$wd/logs";
    my $logdir  = $self->{+LOGDIR};
    my $svc_dir = "$logdir/runs/$self->{+RUN_ID}/services";
    make_path($svc_dir) unless -d $svc_dir;

    $self->{+LOG_NAME}          //= 'run';
    $self->{+NAME}              //= "run-$self->{+RUN_ID}";
    $self->{+HARNESS_NAME}      //= 'harness';
    $self->{+JOB_ID}            //= gen_uuid();
    $self->{+KILL_TIMEOUT}      //= 15;
    $self->{+PARENT_PIDS}       //= [];
    $self->{+STATE}             //= 'running';
    $self->{+RESOURCE_SERVICES} //= {};
    $self->{+TEST_JOBS}         //= {};
    $self->{+WATCH_PIDS}    //= [@{$self->{+PARENT_PIDS}}];
    $self->{+OWN_PGROUP}        //= 0;

    # The run's snapshot .json lives next to the run's .jsonl and is
    # written directly by RunService (not via a logger) because the
    # .json must reflect the run's mutating state at run_on_cleanup
    # time, which only the run-service child sees -- the collector
    # parent that runs logger shutdown has only the pre-fork copy.
    $self->{+SNAPSHOT_FILE} //= "$logdir/runs/$self->{+RUN_ID}.json";

    # Logger specs. Default test_loggers to []; loggers defaults to a
    # JSONL targetting the run-service's own .jsonl via the logger
    # role's path derivation (Collector::Service::Run forces is_run).
    # Apply the default both when the caller passed nothing at all
    # and when they passed an empty arrayref (which is what
    # $run->effective_service_loggers returns when no logger config
    # was supplied).
    $self->{+LOGGERS} //= [];
    $self->{+TEST_LOGGERS} //= [];

    croak "'loggers' must be an arrayref"
        unless ref($self->{+LOGGERS}) eq 'ARRAY';
    croak "'test_loggers' must be an arrayref"
        unless ref($self->{+TEST_LOGGERS}) eq 'ARRAY';

    $self->{+LOGGERS} = [
        'Test2::Harness2::Collector::Logger::JSONL',
    ] unless @{$self->{+LOGGERS}};
}

# Atomic-swap the runs/<run_id>.json snapshot with the run's current
# TO_JSON. Called once at startup (initial state) and once at cleanup
# (final state); the atomic write means downstream readers always see a
# consistent file, never a partial one. The run-service collector
# cannot do this via the JSON logger because the collector process is
# forked from the service before any jobs have run, and only the
# service-side Run object accumulates state as jobs complete.
sub _write_snapshot {
    my $self = shift;
    write_json_file_atomic($self->{+SNAPSHOT_FILE}, $self->{+RUN}->TO_JSON);
    return;
}

# IPC::Manager::Role::Service contract (orig_io, pid, set_pid,
# watch_pids, handle_request) and the default request_handler_terminate
# come from Test2::Harness2::Role::Service. Service-specific handlers
# start here.

# Harness-to-RunService IPC: launch a test job under this run. The
# harness has already done scheduling (needed / available / assign);
# we only spawn the Collector and track its pid, so that the test
# process lives inside the run's subtree and the run service can reap
# it, forward its exit status back, and enforce shutdown cascades.
sub request_handler_launch_job {
    my ($self, $payload) = @_;
    $payload //= {};

    return {ok => 0, error => 'run service not accepting launches'}
        if $self->{+STATE} ne 'running';

    for my $required (qw/job_id test_file/) {
        return {ok => 0, error => "'$required' is required"}
            unless defined $payload->{$required};
    }

    my $job_id   = $payload->{job_id};
    my $job_try  = $payload->{job_try} // 0;
    my $run_id   = $payload->{run_id}  // $self->{+RUN_ID};
    my $log_file = $payload->{log_file};
    my $env      = $payload->{env} // {};
    my $auditor  = $payload->{auditor};
    # Per-job logger spec list. Defaults to the RunService's own
    # TEST_LOGGERS (set at spawn time from the run's effective
    # test_loggers list). Callers can override per-launch via the
    # payload -- not used from the standard harness path but kept
    # for targeted launches (e.g. synth-skip / synth-fail). This
    # service no longer injects any hard-coded JSONL / JSON pair --
    # if the caller wants those, they include the specs (typically
    # with placeholder paths, see below).
    my $payload_loggers = $payload->{loggers} // $self->{+TEST_LOGGERS} // [];
    my $test_file_abs   = $payload->{test_file};
    my $launch_cmd      = $payload->{launch};

    return {ok => 0, error => "'test_file' must be absolute"}
        unless $test_file_abs =~ m{^/};

    # The harness's synthetic-skip / synthetic-fail paths hand us an
    # explicit launch command (perl -e '...'). Default to running the
    # real test file when no override is present.
    $launch_cmd //= [$^X, '-Ilib', $test_file_abs];

    # Default the payload-level log_file only if the caller wants one;
    # loggers are otherwise driven entirely by the payload_loggers
    # specs. Kept for back-compat with callers that pass log_file
    # explicitly.
    $log_file //= undef;

    # Snapshot-style loggers (JSON sidecar) need a 'spec' object to
    # serialize at startup. When the caller did not provide one,
    # synthesize a minimal TestFile from the launch payload's
    # test_file path so the resulting .json includes the relative
    # and absolute test-file paths. Callers that supply their own
    # spec are left alone.
    require Test2::Harness2::TestFile;
    my $test_file_spec = Test2::Harness2::TestFile->new(file => $test_file_abs);

    my @logger_specs = map { _maybe_inject_test_file_spec($_, $test_file_spec) } @$payload_loggers;

    my $handle;
    my $spawn_ok = eval {
        require Test2::Harness2::Collector::Test;
        $handle = Test2::Harness2::Collector::Test->spawn(
            launch       => $launch_cmd,
            new_pgroup   => 1,
            parent_pids  => [$$],
            env_vars     => {T2_FORMATTER => 'Stream2', %$env},
            logdir       => $self->{+LOGDIR},
            run_id       => $run_id,
            job_id       => $job_id,
            job_try      => $job_try,
            ipcm_info    => $self->ipcm_info,
            ipc_parent   => $self->{+NAME},
            ipc_run      => $self->{+NAME},
            ipc_harness  => $self->{+HARNESS_NAME},
            (defined $auditor ? (auditor => $auditor) : ()),
            loggers => [@logger_specs],
        );
        1;
    };
    my $spawn_err = $@;

    unless ($spawn_ok) {
        return {ok => 0, error => "collector spawn failed: $spawn_err"};
    }

    my $pid = $handle->pid;
    $self->{+TEST_JOBS}->{$pid} = {
        job_id     => $job_id,
        job_try    => $job_try,
        run_id     => $run_id,
        pid        => $pid,
        handle     => $handle,
        log_file   => $log_file,
        started_at => time,
    };

    # NOTE: do not register the collector pid as an IPC::Manager worker.
    # The role's reap_children silently consumes worker-pid exits without
    # calling run_on_pid, so we would never see the exit and the harness
    # would never learn the job completed. Keeping it out of the worker
    # map routes the exit through run_on_pid where we forward it via
    # test_job_completed.
    return {ok => 1, pid => $pid, log_file => $log_file};
}

sub request_handler_status {
    my $self = shift;

    my @services;
    for my $svc (values %{$self->{+RESOURCE_SERVICES} // {}}) {
        push @services => {
            pid           => $svc->{pid},
            name          => $svc->{name},
            service_class => $svc->{service_class},
            log_path      => $svc->{log_path},
            restartable   => $svc->{restartable},
            resource      => $svc->{resource}->resource_name,
        };
    }

    my @jobs;
    for my $job (values %{$self->{+TEST_JOBS} // {}}) {
        push @jobs => {
            pid        => $job->{pid},
            run_id     => $job->{run_id},
            job_id     => $job->{job_id},
            job_try    => $job->{job_try},
            log_file   => $job->{log_file},
            started_at => $job->{started_at},
        };
    }

    return {
        service => {
            name     => $self->{+NAME},
            log_name => $self->{+LOG_NAME},
            pid      => $$,
            job_id   => $self->{+JOB_ID},
            workdir  => $self->{+WORKDIR},
            run_id   => $self->{+RUN_ID},
            state    => $self->{+STATE},
        },
        resource_services => \@services,
        test_jobs         => \@jobs,
    };
}

# Role::Service provides run_on_start. These hooks tack on the
# run-specific extras: run_id in the service_started event, the
# initial snapshot, and bringing up the run's resource services.
sub service_started_fields {
    my $self = shift;
    return (run_id => $self->{+RUN_ID});
}

sub service_on_start {
    my $self = shift;

    # Initial snapshot of the run. The final snapshot is written during
    # run_on_cleanup after the state transitions are committed.
    my $snap_ok = eval { $self->_write_snapshot; 1 };
    warn "run-service initial snapshot write failed: $@" unless $snap_ok;

    # Bring up the run's resource services. The harness has already
    # validated the resource set (needed + non-permanent) before
    # spawning us; we just start whatever is configured.
    my $resources = $self->{+RUN}->resources // [];
    $self->start_resource_services($resources, scope => 'run', run => $self->{+RUN})
        if @$resources;

    return;
}

sub run_on_all {
    my ($self, $activity) = @_;

    # Reap any descendants quickly; IPC::Manager's tick drives
    # run_on_pid for exits, so there's nothing more for us to do here
    # beyond letting the loop roll over.
    return;
}

sub run_on_pid {
    my ($self, $pid, $exit) = @_;

    # Test-collector exit: tell the harness so it can release resources
    # and advance its scheduler. The run service's own tracking entry
    # is dropped here; the harness keeps a shadow entry until the
    # test_job_completed message is handled.
    if (my $job = delete $self->{+TEST_JOBS}->{$pid}) {
        $self->_send_to_harness(
            {
                kind    => 'test_job_completed',
                run_id  => $job->{run_id},
                job_id  => $job->{job_id},
                job_try => $job->{job_try},
                pid     => $pid,
                exit    => $exit,
            },
        );
        return;
    }

    # Resource-service exit (handled by the shared host role).
    # Reparented descendants that aren't one of ours silently fall
    # through.
    $self->handle_resource_service_exit($pid, $exit);

    return;
}

sub _send_to_harness {
    my ($self, $msg) = @_;

    my $ok = eval {
        my $handle = IPC::Manager::Service::Handle->new(
            service_name => $self->{+HARNESS_NAME},
            ipcm_info    => $self->ipcm_info,
        );
        $handle->client->send_message($self->{+HARNESS_NAME}, $msg);
        1;
    };
    warn "RunService could not notify harness: $@" unless $ok;
    return;
}

sub run_should_end {
    my $self = shift;

    return 0 unless $self->{+STATE} eq 'terminating';

    # Wait until every resource service AND every test collector we
    # were tracking has exited before we let the loop unwind.
    return 0 if keys %{$self->{+RESOURCE_SERVICES} // {}};
    return 0 if keys %{$self->{+TEST_JOBS}         // {}};
    return 1;
}

sub run_on_cleanup {
    my $self = shift;

    # Final hard-stop in case we're unwinding without a prior terminate
    # (e.g. our parent died). Drain any remaining resource services and
    # test collectors.
    $self->perform_hard_stop
        if keys %{$self->{+RESOURCE_SERVICES} // {}}
        || keys %{$self->{+TEST_JOBS} // {}};

    for my $res (@{$self->{+RUN}->resources // []}) {
        my $ok  = eval { $res->teardown; 1 };
        my $err = $@;
        warn "resource '" . $res->resource_name . "' teardown died: $err"
            unless $ok;
    }

    # Final snapshot -- downstream readers can atomically swap from the
    # queued/running snapshot to the done/final one.
    my $snap_ok = eval { $self->_write_snapshot; 1 };
    warn "run-service final snapshot write failed: $@" unless $snap_ok;

    $self->emit_service_event(kind => 'service_stopped');
}

# ----------------------------------------------------------------------
# Shutdown
# ----------------------------------------------------------------------

# Role::Service hooks. The shared escalator in Role::Service drives the
# TERM/KILL loop; these methods only feed and clean up the run-side
# tracking hashes.
sub hard_stop_pids {
    my $self = shift;

    my %pids;
    for my $info (values %{$self->{+RESOURCE_SERVICES} // {}}) {
        $pids{$info->{pid}} //= {} if $info->{pid};
    }
    for my $info (values %{$self->{+TEST_JOBS} // {}}) {
        $pids{$info->{pid}} //= {} if $info->{pid};
    }

    return %pids;
}

# Mid-loop reap hook: as the escalator reaps a pid, drop it from our
# tracking hashes too so run_should_end sees the updated counts on the
# next tick.
sub service_on_reaped {
    my ($self, $pid) = @_;
    delete $self->{+RESOURCE_SERVICES}->{$pid};
    delete $self->{+TEST_JOBS}->{$pid};
    return;
}

# Post-stop cleanup: anything still tracked after the escalator gave up
# has been IGNORE'd (alive after KILL + grace). Drop it so
# run_should_end sees empty maps.
sub service_post_hard_stop {
    my $self = shift;
    $self->{+RESOURCE_SERVICES} = {};
    $self->{+TEST_JOBS}         = {};
    return;
}

# ----------------------------------------------------------------------
# Emission helper
# ----------------------------------------------------------------------

sub emit_service_event {
    my ($self, %fields) = @_;

    my $em = $self->{+EMITTER} or return;    # no emitter in unit tests
    $em->emit_event(
        job_id  => $self->{+JOB_ID},
        run_id  => $self->{+RUN_ID},
        job_try => 0,
        %fields,
    );

    return;
}

# ----------------------------------------------------------------------
# Entry points
# ----------------------------------------------------------------------

# Take over the current process as a run service. Mirrors the harness
# service's interpose pattern: fork once so the parent becomes the
# run-service collector (with the configured loggers writing the
# run's .jsonl and .json sidecars via the logger role's path rules),
# and the child continues as the actual run-service event loop with
# its STDOUT/STDERR piped through the collector.
sub start {
    my ($class, %args) = @_;

    croak "'ipcm_info' is required" unless defined $args{ipcm_info};

    my $caller_pid = $$;
    $args{parent_pids} //= [$caller_pid];

    my $self = $class->new(%args);

    my $loggers = $self->{+LOGGERS};

    # Everything the interpose child needs after the pipes are wired up.
    my $run_service = sub {
        # The EventEmitter wraps STDOUT (and, when the interpose
        # collector advertises separate pipes via T2_HARNESS2_PIPE_COUNT,
        # STDERR) for the sync marker. We use the process-wide cached
        # instance so anything else in this service that emits shares
        # one wrapper around the real FDs.
        $self->{+EMITTER} = Test2::Harness2::Util::EventEmitter->std;

        my $self_ref = $self;
        local $SIG{TERM} = sub { $self_ref->{+STATE} = 'terminating' };

        my $exit = $self->run;
        POSIX::_exit($exit // 0);
    };

    require Test2::Harness2::Collector::Service::Run;
    Test2::Harness2::Collector::Service::Run->interpose(
        ipcm_info    => $self->ipcm_info,
        ipc_parent   => $self->{+HARNESS_NAME},
        ipc_run      => $self->{+NAME},
        ipc_harness  => $self->{+HARNESS_NAME},
        bus_id       => "collector:" . $self->{+NAME},
        logdir       => $self->{+LOGDIR},
        service_name => $self->{+RUN_ID},
        run_id       => $self->{+RUN_ID},
        loggers      => $loggers,
        parser       => 'Test2::Harness2::Collector::Parser::IOParser',
        parent_pids  => [$caller_pid],
    );

    # Reached only in the interpose child; the interpose parent becomes
    # the collector and exits from _interpose_parent before returning.
    $run_service->();
}

# Fork a run service from the calling process (typically the harness).
# Shares the caller's ipcm_info so both services are on the same bus.
# Returns the child pid in the parent; the child never returns from
# this call.
sub spawn {
    my ($class, %args) = @_;

    croak "'ipcm_info' is required" unless defined $args{ipcm_info};
    croak "'run' is required"       unless defined $args{run};

    my $parent_pid = $$;
    $args{parent_pids} //= [$parent_pid];

    my $pid = fork // die "fork: $!";

    if ($pid) {
        # Parent: just return the pid. Ready-state is signalled via
        # service_started appearing on the IPC bus, but callers that
        # don't need the signal can fire-and-forget.
        return $pid;
    }

    # Child: take over the process and run the service loop.
    $class->start(%args);
    POSIX::_exit(255);    # start() should never return
}

# Auto-inject 'spec' for Logger::JSON when the caller did not
# provide one. Without a spec the snapshot file is written with
# only exit/pass and no identifying fields; injecting a TestFile
# here gives the .json the file / absolute / relative paths the
# consumer expects. Blessed instances pass through untouched.
sub _maybe_inject_test_file_spec {
    my ($spec, $test_file_spec) = @_;

    return $spec if blessed($spec);
    return $spec unless $test_file_spec;

    my $class = ref($spec) eq 'ARRAY' ? $spec->[0] : $spec;
    return $spec unless defined $class && !ref($class);
    return $spec unless $class eq 'Test2::Harness2::Collector::Logger::JSON';

    if (ref($spec) eq 'ARRAY') {
        my %args = @{$spec}[1 .. $#$spec];
        return $spec if exists $args{spec};
        $args{spec} = $test_file_spec;
        return [$class, %args];
    }

    # Bare class-name spec: upgrade to [$class, spec => $tf].
    return [$class, spec => $test_file_spec];
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::RunService - Per-run supervisor service forked by the
harness for every test run.

=head1 DESCRIPTION

Every time L<Test2::Harness2> accepts a run for launch it forks one of
these as a child process. The run service exists for the lifetime of
the run and has two jobs:

=over 4

=item * Host the run's resource services

Per-run resources (those attached to C<< $run->resources >>) have their
C<service_*> methods invoked here, so any subprocess a resource spawns
is a grandchild of the harness and a direct child of the run service.
The process tree mirrors the ownership model: per-run services live
under their run, not under the harness.

=item * Produce a collected per-run log

Its stdout and stderr are piped through the standard collector with
loggers attached, so every run has a C<runs/E<lt>run_idE<gt>/services/E<lt>nameE<gt>.jsonl>
file that records C<service_started>, C<service_stopped>, and any
diagnostic output the run service or its children emit.

=back

The run service is started even when the run has no resources attached
-- the per-run log is useful on its own, and the consistent shape means
downstream tooling doesn't have to special-case runs with no resources.

Scheduling stays in L<Test2::Harness2> itself; the run service does not
make launch decisions.

=head1 ATTRIBUTES

=over 4

=item workdir (required)

Working directory for the run (the same one the harness uses).

=item run (required)

The L<Test2::Harness2::Run> being supervised.

=item run_id

Defaulted from C<< $run->run_id >>.

=item name

Service name. Defaults to C<'run'>; the name determines the log file:
C<< <workdir>/runs/<run_id>/services/<name>.jsonl >>. Also reserved in
this run's per-run service-name scope so a resource service can't
collide with it.

=item ipcm_info (required for spawn/start)

L<IPC::Manager> bus info. Typically inherited from the harness.

=item parent_pids

Pids the service should self-terminate with. Defaults to the caller
(harness) pid.

=item kill_timeout

Seconds to wait between TERM and KILL during shutdown. Default C<15>.

=back

=head1 METHODS

=over 4

=item $pid = Test2::Harness2::RunService->spawn(%args)

Fork from the caller and launch a run service child. Returns the pid
in the parent; the child never returns.

=item Test2::Harness2::RunService->start(%args)

Run the service loop in the current process (after the harness has
already forked). Does not return.

=item $rv = $svc->request_handler_terminate

IPC handler: initiate a hard stop. TERMs tracked resource services
(escalating to KILL after C<kill_timeout> seconds) and exits.

=item $rv = $svc->request_handler_status

IPC handler: snapshot of the run service state including every tracked
resource service.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

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

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
