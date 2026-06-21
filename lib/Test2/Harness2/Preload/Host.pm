package Test2::Harness2::Preload::Host;
use strict;
use warnings;

our $VERSION = '2.000000';

use File::Spec();

use Carp qw/confess croak/;
use POSIX qw/:sys_wait_h/;
use Long::Jump qw/setjump longjump/;
use Time::HiRes qw/sleep time/;

use Test2::Harness2::Util qw/clean_path mod2file parse_exit process_includes chmod_tmp write_file/;
use Test2::Harness2::Util::JSON(qw/encode_json/);

use Test2::Harness2::Runner::Constants;

use Test2::Harness2::Runner::Run();
use Test2::Harness2::Runner::Job();
use Test2::Harness2::Runner::Spawn();
use Test2::Harness2::Runner::Preload();
use Test2::Harness2::Runner::Preloader();
use Test2::Harness2::Runner::StageProcess();
use Test2::Harness2::Runner::StageDelegate();

use parent 'Test2::Harness2::IPC';
use Test2::Harness2::Util::HashBase(
    # Fields from settings
    qw{
        <job_count <slots_per_job

        <includes <tlib <lib <blib
        <unsafe_inc

        <use_fork <preloads <preload_threshold <switches
        <restrict_reload

        <cover

        <event_timeout <post_exit_timeout <resource_timeout

        <resources

        <nytprof

        <reload
    },
    # From Construction
    qw{
        <dir <settings <fork_job_callback <fork_spawn_callback <monitor_preloads
        <jobs_todo <dump_depmap <persist
    },
    # Other
    qw {
        +preloader

        <stage
        <signal

        +last_timeout_check
        +timeout_signaled
        +run_reached_timeout
        +can_stage
        <tmp_dir

        <rootpid

        +stage_delegate

        +job_pids

        +preload_warnings
    },
);

use Role::Tiny::With;
with 'Test2::Harness2::Role::Service';

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Preload::Host - The preload-root stage host (preload + launch
tests, no scheduler).

=head1 DESCRIPTION

This is the in-process stage host that the preload-root
(L<Test2::Harness2::Preload>) drives. It is a B<completely independent> class
from L<Test2::Harness2::Runner>: neither inherits from the other, and they share
only the L<Test2::Harness2::Role::Service> role (both have a listen socket and
manage connections).

Where the runner is the harness B<scheduler> -- it owns the canonical run State,
serves clients/stages over C<runner.socket>, and launches tests only as
clean-slate fork+exec -- the host has B<no scheduler> and B<no canonical run
State>. It preloads the user's libraries, forks/hosts the named preload stages,
dials the runner over C<runner.socket>, registers each stage, and launches the
tests it is dispatched (C<goto::file> in-process).

The host runs inside the preload-root process. Its C<rootpid> is the B<real
runner's> pid (never C<$$>): the base/default stage is hosted in THIS process and
the named stages are forked as its children; every stage is a socket-dispatch
service (binds C<< preload-E<lt>stageE<gt>.socket >>, dials C<runner.socket>, and
receives dispatched work + reports outcomes over the one registered channel it
opened to the runner).

=head1 SYNOPSIS

    # Built and driven by Test2::Harness2::Preload::_run_stage_host, never by hand.

=cut

sub job_class { 'Test2::Harness2::Runner::Job' }

# Every Preload::Host process is a forked preload stage acting as a socket-dispatch
# service (the base/default stage in the preload-root process, or a named stage
# forked from it). The root process keeps the 'runner' name / runner.socket; a
# stage rebinds the service socket to 'preload-<stage>.socket'.
sub name { 'runner' }

sub workdir { my $self = shift; return $self->{+DIR} }

sub service_name {
    my $self = shift;
    my $stage = $self->{+STAGE} // return 'runner';
    return "preload-$stage";
}

# True once this process has become a forked preload stage (STAGE set). Before the
# run_stage loop sets STAGE it is the pre-stage host scaffold.
sub is_stage_service {
    my $self = shift;
    return $self->{+STAGE} ? 1 : 0;
}

sub init {
    my $self = shift;

    croak "'rootpid' is a required attribute (the real runner pid)"
        unless $self->{+ROOTPID};

    $self->{+JOB_PIDS} = {};

    croak "'dir' is a required attribute"      unless $self->{+DIR};
    croak "'settings' is a required attribute" unless $self->{+SETTINGS};

    my $dir = clean_path($self->{+DIR});

    croak "'$dir' is not a valid directory"
        unless -d $dir;

    $self->{+DIR} = $dir;

    $self->{+HANDLERS}->{HUP} = sub {
        my $sig = shift;

        # The host reloads by re-execing the whole preload tree. Its base/default
        # stage signals the reload by setting SIGNAL=HUP, which its end_test_loop
        # turns into a respawn (longjump 'preload-root').
        print "$$ $0 ($self->{+STAGE}) Preload::Host caught SIG$sig, reloading...\n";
        $self->{+SIGNAL} = $sig;
    };

    my $tmp_dir = File::Spec->catdir($self->{+DIR}, 'tmp');
    unless (-d $tmp_dir) {
        mkdir($tmp_dir) or die "Could not create temp dir: $!";
        chmod_tmp($tmp_dir);
    }
    $self->{+TMP_DIR} = $tmp_dir;

    my $have_job_limiter = 0;
    for my $res (@{$self->{+RESOURCES}}) {
        require(mod2file($res)) unless ref($res);
        $have_job_limiter++ if $res->job_limiter;
    }

    unless ($have_job_limiter) {
        require Test2::Harness2::Runner::Resource::JobCount;
        unshift @{$self->{+RESOURCES}} => 'Test2::Harness2::Runner::Resource::JobCount';
    }

    $self->SUPER::init();
}

sub preloader {
    my $self = shift;

    $self->{+PRELOADER} //= Test2::Harness2::Runner::Preloader->new(
        dir             => $self->{+DIR},
        persist         => $self->{+PERSIST},
        preloads        => $self->preloads,
        monitor         => $self->{+MONITOR_PRELOADS},
        restrict_reload => $self->{+RESTRICT_RELOAD},
        dump_depmap     => $self->{+DUMP_DEPMAP},
        reload          => $self->{+RELOAD},

        # The real runner pid, so each stage collector watches it and
        # self-terminates if the runner dies (ARCHITECTURE.md §4.1).
        runner_pid      => $self->{+ROOTPID},

        below_threshold => ($self->{+PRELOAD_THRESHOLD} && $self->{+JOBS_TODO} && $self->{+PRELOAD_THRESHOLD} > $self->{+JOBS_TODO}) ? 1 : 0,
    );
}

# The host never holds canonical scheduling State: every stage receives work over
# its own socket and reports outcomes back to the runner. The lightweight in-stage
# delegate exposes the next_task/run/stop_task/retry_task API run_job/set_proc_exit
# call, so the shared run loop is unchanged.
sub state {
    my $self = shift;
    return $self->stage_delegate;
}

# The lightweight in-stage delegate a forked preload stage uses in place of State.
# Built once per stage child; it holds the dispatched task queue and reports
# outcomes back to the runner via service_send over the single registered service
# channel (the connection the stage opened to send stage_ready).
sub stage_delegate {
    my $self = shift;
    return $self->{+STAGE_DELEGATE} //= Test2::Harness2::Runner::StageDelegate->new(
        workdir => $self->{+DIR},
        name    => $self->{+STAGE},
        runner  => $self,
    );
}

# Build the stage map reported to the runner from the merged preload meta the
# guarded preload produced: each user-defined stage name maps to whether it is the
# default. The runner resolves a test's stage client-side from the test's preload
# directives against this map, so the map only needs to say which stages exist and
# which is the default. Returns an empty hashref when there is no staged preload
# (the runner still needs the empty map to know the data has arrived).
sub stage_data {
    my $self = shift;

    my $meta = $self->preloader->staged;

    my $data = {};
    return $data unless $meta;

    my $lookup  = $meta->stage_lookup;
    my $default = $meta->default_stage;

    for my $name (keys %$lookup) {
        $data->{$name} = {
            default => (defined($default) && $name eq $default) ? 1 : 0,
        };
    }

    return $data;
}

# Stage-host request handlers. The runner (the scheduler) dispatches work to each
# stage over the one registered channel the stage opened to it; Role::Service's
# handle_request routes those commands to these handlers. These are the ONLY
# requests a stage host serves -- it does not own canonical State, so it has none
# of the runner's scheduler / state-hub handlers. (`stop` is handled by
# Role::Service itself.)

# The runner's scheduler dispatches an already-resolved task (resources merged) plus
# the run definition; the stage delegate queues it and the stage's run loop forks it
# from the preloaded interpreter. One-way: the runner does not read a reply.
sub request_handler_run_task {
    my $self = shift;
    my ($payload) = @_;
    $self->state->enqueue_task($payload->{task}, $payload->{run});
    return undef;
}

# A monitored stage forwards a reload/monitor notification so the runner's reload
# state (diagnostics) stays current; the stage delegate relays it to the runner.
# One-way.
sub request_handler_reload {
    my $self = shift;
    my ($payload) = @_;
    $self->state->reload($payload->{stage}, $payload->{data});
    return undef;
}

sub check_timeouts {
    my $self = shift;

    return unless $self->settings->runner->use_timeout;

    my $now = time;

    # Check only once per second, that is as granular as we get.
    return if $self->{+LAST_TIMEOUT_CHECK} && $now < (1 + $self->{+LAST_TIMEOUT_CHECK});

    # The per-test silence and lifetime timeouts are enforced by the
    # Test2-Collector collector parent itself. What remains is a backstop for a
    # collector PARENT that should have exited but has not: once a job process has
    # been reaped (it is in WAITING) we give it a grace window, then escalate
    # TERM -> KILL so a wedged collector cannot hang the run.
    my $grace = $self->{+POST_EXIT_TIMEOUT} || 60;

    my $signaled = $self->{+TIMEOUT_SIGNALED} //= {};

    delete $signaled->{$_} for grep { !$self->{+PROCS}->{$_} } keys %$signaled;

    for my $pid (keys %{$self->{+PROCS}}) {
        my $job = $self->{+PROCS}->{$pid};
        next unless $job->isa('Test2::Harness2::Runner::Job');

        my $waiting = $self->{+WAITING}->{$pid} or next;
        my $since   = $waiting->[1] // $now;
        next unless ($now - $since) > $grace;

        my $kill = $signaled->{$pid}++;

        my $sigmap = $self->SIG_MAP;
        my $sig    = $kill ? $sigmap->{'KILL'} : $sigmap->{'TERM'};
        $sig = "-$sig" if $self->USE_P_GROUPS;

        print STDERR "$$ $0 " . $job->file . " collector process-group did not fully exit after the collector was reaped, sending " . ($kill ? 'SIGKILL' : 'SIGTERM') . " to $pid...\n";

        $self->{+RUN_REACHED_TIMEOUT} //= {};
        $self->{+RUN_REACHED_TIMEOUT}->{$job->task->{job_id}} = $pid;

        kill($sig, $pid);
    }

    $self->{+LAST_TIMEOUT_CHECK} = time;
}

sub stop {
    my $self = shift;

    $self->check_for_fork;

    if (keys %{$self->{+PROCS}}) {
        print "$$ $0 Sending all child processes the TERM signal...\n";
        $self->killall($self->{+SIGNAL} // 'TERM');
        $self->wait(all => 1, timeout => 5);
    }

    if (keys %{$self->{+PROCS}}) {
        local $?;
        print STDERR "$$ $0 Some child processes are refusing to exit, sending KILL signal...\n";
        print("$$ $0 == $_ " . waitpid($_, WNOHANG) . "\n") for keys %{$self->{+PROCS}};
        $self->killall('KILL');
    }

    $self->SUPER::stop();
}

sub handle_sig {
    my $self = shift;
    my ($sig) = @_;

    return if $self->{+SIGNAL};

    return $self->{+HANDLERS}->{$sig}->($sig) if $self->{+HANDLERS}->{$sig};

    $self->{+SIGNAL} = $sig;
    die "Preload::Host caught SIG$sig. Attempting to shut down cleanly...\n";
}

sub all_libs {
    my $self = shift;

    my @out;

    push @out => @{$self->{+INCLUDES}} if $self->{+INCLUDES};

    push @out => 't/lib' if $self->{+TLIB};
    push @out => 'lib'   if $self->{+LIB};

    if ($self->{+BLIB}) {
        push @out => 'blib/lib';
        push @out => 'blib/arch';
    }

    return @out;
}

sub process {
    my $self = shift;

    @INC = process_includes(
        list            => [@{$self->settings->harness->dev_libs}, $self->all_libs],
        include_dot     => $self->unsafe_inc,
        include_current => 1,
        clean           => 1,
    );

    # The host does NOT write the workdir PID file (that names the real runner) and
    # does NOT bind runner.socket (the real runner owns it); its stages bind their
    # own preload-<stage>.socket in run_stage and dial the real runner.socket.

    # Propagate the workdir to every child (collectors, stages, jobs) so they can
    # locate runner.socket (ARCH 5.3).
    $ENV{T2_HARNESS_WORKDIR} = $self->{+DIR};

    $self->start();

    my $ok  = eval { $self->run_tests(); 1 };
    my $err = $@;
    $self->{+CAN_STAGE} = 0;

    warn $err unless $ok;

    $self->stop();

    return $self->{+SIGNAL} ? 128 + $self->SIG_MAP->{$self->{+SIGNAL}} : $ok ? 0 : 1;
}

# Ask each forked stage service to shut down cleanly at run end. Stage
# children idle waiting for dispatches and never see the run end on their own, so
# the host must tell them over the SAME registered channel each stage opened to the
# runner -- these are THIS host's own stage children, stopped via service_send to
# their peer identity.
sub stop_stages {
    my $self = shift;

    my %live_stage;
    for my $proc (values %{$self->{+PROCS} // {}}) {
        next unless $proc->isa('Test2::Harness2::Runner::StageProcess');
        $live_stage{$proc->name} = 1;
    }

    for my $stage (keys %live_stage) {
        eval { $self->service_send("preload-$stage", 'stop'); 1 };
    }

    return;
}

sub run_tests {
    my $self = shift;

    my $preloader = $self->preloader;

    # Load the preloads ONCE, here, under the test2_start_preload guard preload()
    # establishes -- so a preload's require-time Test2 side effects stay inside the
    # guard and no module loads twice (the preload-root handshake deliberately does
    # NOT pre-load them). Capture any preload-time warnings (on the persistent path a
    # broken preload is tolerated with a warn rather than a die) so the base stage can
    # forward them to the runner alongside the stage map -- otherwise they would never
    # reach a `yath run` client, since the persistent stage host does not exit.
    my @warnings;
    {
        local $SIG{__WARN__} = sub {
            push @warnings => $_[0];
            print STDERR $_[0];
        };
        $preloader->preload();
    }
    $self->{+PRELOAD_WARNINGS} = \@warnings;

    my ($stage, @procs) = $preloader->preload_stages();

    if ($self->dump_depmap) {
        if (my $dtrace = $preloader->dtrace) {
            if (my $depmap = $dtrace->dep_map) {
                my $file = "depmap-$stage.json";
                write_file($file, encode_json($depmap));
            }
        }
    }

    $self->watch($_) for @procs;

    while (1) {
        $self->{+CAN_STAGE} = 1;
        my $jump = setjump "Stage-Runner" => sub {
            $self->run_stage($stage);
        };

        last unless $jump;

        ($stage) = @$jump;
        $self->reset_stage();
    }

    return;
}

# The stage child dials the runner's one service channel. runner.socket is
# the global flat socket in the workdir (bound by the real runner long before any
# stage forks). The dialed connection joins this process's service set, so the
# runner's dispatches (run_task / stop) are read off it and the stage's reports ride
# back up it -- one channel both ways (ARCHITECTURE.md §5.2).
sub _connect_runner {
    my $self = shift;

    my $path  = File::Spec->catfile($self->{+DIR}, 'runner.socket');
    my $start = time();

    while (1) {
        return 1 if $self->service_connect_peer('runner', $path);
        croak "Timed out connecting to runner.socket from stage '$self->{+STAGE}'"
            if (time() - $start) > 30;
        sleep 0.05;
    }
}

sub reset_stage {
    my $self = shift;

    # Normalize IPC
    $self->check_for_fork();

    # If no stage was set we do not want to clear this, root stages need to
    # preserve the preloads
    return unless $self->{+STAGE};

    delete $self->{+STAGE};
    delete $self->{+STAGE_DELEGATE};
    delete $self->{+LAST_TIMEOUT_CHECK};

    return;
}

sub run_stage {
    my $self = shift;
    my ($stage) = @_;

    $self->{+STAGE} = $stage;

    # A forked preload stage becomes a dispatch service: it drops the runner.socket
    # listen descriptor it inherited and binds its own preload-<stage>.socket
    # (reserved for `yath spawn`, ARCHITECTURE.md §4.8). It then opens the one
    # registered service channel to the runner and announces readiness over it.
    my $stage_service = $self->is_stage_service;
    if ($stage_service) {
        $self->reset_service;
        $self->start_service;

        # Open the ONE registered service channel to the runner
        # (ARCHITECTURE.md §5.2) and announce readiness over it. The runner
        # reads stage_ready / outcome reports off this connection AND
        # dispatches jobs back down it.
        $self->_connect_runner;

        # The base/default stage -- the one holding the full merged preload meta --
        # reports the stage map (which stages exist + which is default) and any
        # preload-time warnings to the runner over this channel, BEFORE its
        # stage_ready. The runner gates dispatch on both the map AND the base stage
        # being ready, so sending the map first guarantees it lands before any task is
        # scheduled. Forked named stages inherit the same meta but must not re-report.
        if ($stage eq 'base' || $stage eq 'default') {
            $self->service_send('runner', 'set_stage_data', stage_data => $self->stage_data);

            if (my $warnings = $self->{+PRELOAD_WARNINGS}) {
                $self->service_send('runner', 'preload_warnings', warnings => [@$warnings])
                    if @$warnings;
            }
        }

        $self->service_send('runner', 'stage_ready', stage => $stage);
    }
    else {
        $self->state->stage_ready($stage);
    }

    while (1) {
        # Stage service: accept dispatched jobs on the registered channel. No
        # scheduler here -- the runner schedules and dispatches; this process only
        # forks/reaps the jobs it is handed and reports outcomes back.
        if ($stage_service) {
            $self->service_io;
            $self->{+SIGNAL} //= 'TERM' if $self->service_stopped;
        }

        next if $self->run_job();

        next if $self->wait();

        last if $self->end_test_loop();

        sleep($self->{+WAIT_TIME}) if $self->{+WAIT_TIME};
    }

    if ($stage_service) {
        # §6.8 (§4.7/§4.7a): a stage that exits while it is still in the stage map is
        # "coming back" -- the preload-root respawns it and the fresh incarnation
        # re-readies -- so it reports 'restarting', not 'down'.
        eval { $self->service_send('runner', 'stage_restarting', stage => $stage); 1 };
        $self->close_service;
    }
    else {
        $self->state->stage_restarting($stage);
    }

    # Stage services (this process's own stage children, and a nested stage's
    # grandchildren) idle waiting for dispatches; tell each live child stage to shut
    # down cleanly before the wait(all=>1) below.
    $self->stop_stages;

    $self->killall($self->{+SIGNAL}) if $self->{+SIGNAL};

    $self->wait(all => 1);

    exit 0 unless $stage eq 'base' || $stage eq 'default';
}

sub run_job {
    my $self = shift;

    my $task = $self->state->next_task($self->{+STAGE}) or return 0;

    if ($task->{spawn} && !$task->{resource_skip}) {
        my $job = Test2::Harness2::Runner::Spawn->new(
            runner        => $self,
            task          => $task,
            settings      => $self->settings,
            fork_callback => $self->{+FORK_SPAWN_CALLBACK},
        );

        $self->{+FORK_SPAWN_CALLBACK}->($self, $job);
        return 1;
    }

    my $run = $self->state->run();
    return 1 unless $run;

    my $job_class;
    if ($task->{job_class}) {
        $job_class = $task->{job_class};
        require(mod2file($job_class));

        die "Custom job class $job_class overrode the category, this is a fatal mistake"
            unless $job_class->category eq $self->job_class->category;
    }
    else {
        $job_class = $self->job_class;
    }

    my $job = $job_class->new(
        runner        => $self,
        task          => $task,
        run           => $run,
        settings      => $self->settings,
        fork_callback => $self->{+FORK_JOB_CALLBACK},
    );

    $job->prepare_dir();

    my $pid;
    my $via = $job->via();
    if ($via) {
        require(mod2file($1)) if !defined(&{$via}) && $via =~ m/^(.+)::[^:]+$/;

        $pid = $self->$via($job);
        $job->set_pid($pid);
        $self->watch($job);
    }
    else {
        $self->spawn($job);
        $pid = $job->pid;
    }

    # The stage reports the forked job's pid back up its one registered
    # channel (the stage delegate's job_pid -> service_send('runner', ...)).
    eval { $self->state->job_pid($task->{job_id}, $pid); 1 };

    return $pid;
}

sub orphaned {
    my $self = shift;

    return 0 if $self->{+SIGNAL};

    my $dir = $self->{+DIR};
    return 1 if $dir && !-d $dir;

    my $pfile = $self->{+PERSIST};
    return 1 if $pfile && !-e $pfile;

    return 0;
}

sub end_test_loop {
    my $self = shift;

    if ($self->orphaned) {
        $self->{+SIGNAL} //= 'TERM';
        return 1;
    }

    my $state = $self->state;

    no warnings 'uninitialized';
    if ($self->preloader->check($state)) {
        $self->{+SIGNAL} //= 'HUP';
        return 1;
    }

    return 1 if $self->{+SIGNAL};

    return 1 if $state->done;

    return 0;
}

sub set_proc_exit {
    my $self = shift;
    my ($proc, $exit, $time, @args) = @_;

    if ($proc->isa('Test2::Harness2::Runner::Job')) {
        my $task = $proc->task;

        delete $self->{+JOB_PIDS}->{$task->{job_id}};

        my $timed_out = 0;
        if (!$exit && ref $self->{+RUN_REACHED_TIMEOUT} && $self->{+RUN_REACHED_TIMEOUT}->{$task->{job_id}}) {
            delete $self->{+RUN_REACHED_TIMEOUT}->{$task->{job_id}};
            $timed_out = 1;
        }

        if (($exit || $timed_out) && $proc->is_try < ($proc->retry // 0)) {
            $self->state->retry_task($task->{job_id});
            push @args => 'will-retry';
        }
        else {
            $self->state->stop_task($task->{job_id});
        }

        if (my $bail = $exit ? $proc->bailed_out : 0) {
            print "$$ $0 BAIL-OUT detected: $bail\n";
            if ($self->settings->runner->abort_on_bail) {
                print "$$ $0 Aborting the test run...\n";
                $self->state->halt_run($task->{run_id});
            }
        }
    }
    elsif ($proc->isa('Test2::Harness2::Runner::StageProcess')) {
        my $stage = $proc->name;

        if ($exit != 0) {
            my $e   = parse_exit($exit);
            my $err = "$$ $0 Child stage '$stage' did not exit cleanly (sig: $e->{sig}, err: $e->{err})!\n";
            $self->{+MONITOR_PRELOADS} ? warn $err : die $err;
        }

        if ($self->{+MONITOR_PRELOADS} && $self->{+CAN_STAGE} && !$self->end_test_loop) {
            my $pid = $$;
            my ($name, @procs) = $self->preloader->_preload_stages($stage);
            $self->watch($_) for @procs;
            longjump "Stage-Runner" => $name unless $pid == $$;
        }
    }

    $self->SUPER::set_proc_exit($proc, $exit, $time, @args);
}

1;

__END__

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
