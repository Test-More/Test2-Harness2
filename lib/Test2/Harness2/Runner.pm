package Test2::Harness2::Runner;
use strict;
use warnings;

our $VERSION = '2.000000';

use File::Spec();

use Carp qw/confess croak/;
use POSIX qw/:sys_wait_h/;
use Long::Jump qw/setjump longjump/;
use Time::HiRes qw/sleep time/;

use Test2::Harness2::Util qw/clean_path file2mod mod2file parse_exit write_file_atomic process_includes chmod_tmp write_file/;
use Test2::Harness2::Util::Queue();
use Test2::Harness2::Util::JSON(qw/encode_json/);

use Test2::Harness2::Runner::Constants;

use Test2::Harness2::Runner::Run();
use Test2::Harness2::Runner::Job();
use Test2::Harness2::Runner::Spawn();
use Test2::Harness2::Runner::State();
use Test2::Harness2::Runner::Preload();
use Test2::Harness2::Runner::Preloader();
use Test2::Harness2::Runner::Preloader::Stage();
use Test2::Harness2::Runner::DepTracer();

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
        <dir <settings <fork_job_callback <fork_spawn_callback <respawn_runner_callback <monitor_preloads
        <jobs_todo <dump_depmap <persist
    },
    # Other
    qw {
        +preloader
        +state

        <stage
        <signal

        +last_timeout_check
        +timeout_signaled
        +can_stage
        <tmp_dir

        +scheduler_errors

        <rootpid
    },
);

use Role::Tiny::With;
with 'Test2::Harness2::Role::Service';

sub job_class  { 'Test2::Harness2::Runner::Job' }

# The runner service is the canonical 'runner.socket' in the workdir (ARCH 4.2,
# 5.3). 'workdir' and 'name' satisfy Test2::Harness2::Role::Service.
sub name    { 'runner' }
sub workdir { my $self = shift; return $self->{+DIR} }

# Test2::Harness2::IPC owns child reaping for this process (via wait /
# _bring_out_yer_dead, which dies on an unexpected waitpid). The service role's
# own reap_children would race that path, so it is disabled here: the runner
# polls the socket but reaps through IPC.
sub reap_children { my $self = shift; return }

our $RUNNER_PID;
sub init {
    my $self = shift;

    $self->{+ROOTPID} = $$;
    $RUNNER_PID = $$;

    croak "'dir' is a required attribute"      unless $self->{+DIR};
    croak "'settings' is a required attribute" unless $self->{+SETTINGS};

    my $dir = clean_path($self->{+DIR});

    croak "'$dir' is not a valid directory"
        unless -d $dir;

    $self->{+DIR} = $dir;

    $self->{+HANDLERS}->{HUP} = sub {
        my $sig = shift;
        print "$$ $0 ($self->{+STAGE}) Runner caught SIG$sig, reloading...\n";
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

        below_threshold => ($self->{+PRELOAD_THRESHOLD} && $self->{+JOBS_TODO} && $self->{+PRELOAD_THRESHOLD} > $self->{+JOBS_TODO}) ? 1 : 0,
    );
}

sub state {
    my $self = shift;

    my $preloader = $self->preloader;

    my $settings = $self->settings;
    $self->{+STATE} //= Test2::Harness2::Runner::State->new(
        workdir      => $self->{+DIR},
        eager_stages => $preloader->eager_stages // {},
        preloader    => $preloader,
        resources    => [map { $_->new(settings => $settings) } @{$self->{+RESOURCES}}],
        settings     => $settings,
    );
}

sub check_timeouts {
    my $self = shift;

    return unless $self->settings->runner->use_timeout;

    my $now = time;

    # Check only once per second, that is as granular as we get. Also the check is not cheep.
    return if $self->{+LAST_TIMEOUT_CHECK} && $now < (1 + $self->{+LAST_TIMEOUT_CHECK});

    # The per-test silence and lifetime timeouts are now enforced by the
    # Test2-Collector collector parent itself (via collect(silence_timeout =>
    # ..., lifetime_timeout => ...)): it kills the test child's process group,
    # records the timeout in events.jsonl.zst, and exits. The runner no longer
    # tracks per-job output activity or writes event_timeout/post_exit_timeout
    # marker files.
    #
    # What remains here is a backstop for a collector PARENT that should have
    # exited but has not: once a job process has been reaped (it is in WAITING)
    # we give it a grace window, then escalate TERM -> KILL so a wedged
    # collector cannot hang the run.
    my $grace = $self->{+POST_EXIT_TIMEOUT} || 60;

    my $signaled = $self->{+TIMEOUT_SIGNALED} //= {};

    # Drop entries for pids that are no longer live, so a future job that reuses
    # a pid does not inherit a stale "already TERMed, escalate to KILL" flag.
    delete $signaled->{$_} for grep { !$self->{+PROCS}->{$_} } keys %$signaled;

    for my $pid (keys %{$self->{+PROCS}}) {
        my $job = $self->{+PROCS}->{$pid};
        next unless $job->isa('Test2::Harness2::Runner::Job');

        my $waiting = $self->{+WAITING}->{$pid} or next;
        my $since   = $waiting->[1] // $now;
        next unless ($now - $since) > $grace;

        my $kill = $signaled->{$pid}++;

        my $sigmap = $self->SIG_MAP;
        my $sig = $kill ? $sigmap->{'KILL'} : $sigmap->{'TERM'};
        $sig = "-$sig" if $self->USE_P_GROUPS;

        print STDERR "$$ $0 " . $job->file . " collector process-group did not fully exit after the collector was reaped, sending " . ($kill ? 'SIGKILL' : 'SIGTERM') . " to $pid...\n";

        $self->{run_reached_timeout} //= {};
        $self->{run_reached_timeout}->{$job->task->{job_id}} = $pid;

        kill($sig, $pid);
    }

    $self->{+LAST_TIMEOUT_CHECK} = time;
}

sub stop {
    my $self = shift;

    $self->check_for_fork;

    if (keys %{$self->{+PROCS}}) {
        print "$$ $0 Sending all child processes the TERM signal...\n";
        # Send out the TERM signal
        $self->killall($self->{+SIGNAL} // 'TERM');
        $self->wait(all => 1, timeout => 5);
    }

    # Time to get serious
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
    die "Runner caught SIG$sig. Attempting to shut down cleanly...\n";
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

    my $pidfile = File::Spec->catfile($self->{+DIR}, 'PID');
    write_file_atomic($pidfile, "$$");

    # Propagate the workdir to every child (collectors, stages, jobs) so they can
    # locate runner.socket without hardcoded assumptions (ARCH 5.3). Setting it in
    # the runner process means forked stages inherit it directly, and the
    # Test2::Collector child_env merge carries it on into test children; jobs also
    # set it explicitly in their curated env (Runner::Job::env_vars).
    $ENV{T2_HARNESS_WORKDIR} = $self->{+DIR};

    # Bind runner.socket and run the accept/request loop coexisting with the
    # run loop (chunk 5a scaffolding). The scheduler is now an in-runner object
    # ticked each service-loop iteration (chunk 5b); dispatch.jsonl/dispatch.lock
    # are gone. queue.jsonl/jobs.jsonl/run_queue.jsonl stay this phase (socket
    # run-submission is chunk 5c).
    $self->start_service;

    $self->start();

    my $ok  = eval { $self->run_tests(); 1 };
    my $err = $@;
    $self->{+CAN_STAGE} = 0;

    warn $err unless $ok;

    $self->stop();

    $self->close_service;

    return $self->{+SIGNAL} ? 128 + $self->SIG_MAP->{$self->{+SIGNAL}} : $ok ? 0 : 1;
}

sub service_tick {
    my $self = shift;

    # A 'stop' request over runner.socket asks the run loop to wind down. The
    # role's request_handler_stop sets service_stopped; translate that into the
    # runner's own shutdown signal so the run loop (run_stage) terminates through
    # end_test_loop.
    $self->{+SIGNAL} //= 'TERM' if $self->service_stopped;

    # The scheduler is an in-runner object (chunk 5b): advance it here, on the
    # same service-loop cadence the socket I/O runs on, instead of in a separate
    # process polling dispatch.jsonl under a flock.
    $self->scheduler_tick;

    return;
}

# How many consecutive scheduler-logic failures the runner tolerates before it
# gives up and aborts the run. A scheduler used to be a separate process that
# could die and be detected via waitpid; now that it is in-runner code, a
# failure (e.g. a resource that dies in tick()) surfaces here directly. We retry
# a few times so a transient error self-heals, then abort cleanly with a useful
# diagnostic rather than spinning or silently hanging.
sub SCHEDULER_MAX_ERRORS { 5 }

sub scheduler_tick {
    my $self = shift;

    # Only the root runner process schedules; forked stage children do not.
    return unless $self->{+ROOTPID} == $$;

    # Once we are winding down there is no point advancing the scheduler.
    return if $self->{+SIGNAL};

    my $state = $self->state;

    my $ok = eval {
        $state->poll;

        while (1) {
            next if $state->advance;
            last;
        }

        if (my $idle = $state->resource_timeout($self->{+RESOURCE_TIMEOUT})) {
            print STDERR "\n\nyath: Resource timeout after ${idle}s with no tests able to start. Aborting.\n";
            print STDERR "There are pending tests but resources have not become available.\n";
            print STDERR "Use --resource-timeout to adjust or disable (0) this timeout.\n\n";
            $state->truncate();
            $self->{+SIGNAL} = 'TERM';
        }

        1;
    };

    if ($ok) {
        $self->{+SCHEDULER_ERRORS} = 0;
        return;
    }

    my $err = $@;
    my $count = ++$self->{+SCHEDULER_ERRORS};
    my $max   = $self->SCHEDULER_MAX_ERRORS;
    print STDERR "\n$$ $0 Scheduler error ($count/$max): $err\n";

    if ($count >= $max) {
        print STDERR "$$ $0 Scheduler aborting after $count consecutive errors.\n";
        $self->{+SIGNAL} //= 'TERM';
    }

    return;
}

sub run_tests {
    my $self = shift;

    my $preloader = $self->preloader;
    $preloader->preload();

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

    while(1) {
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

sub reset_stage {
    my $self = shift;

    # Normalize IPC
    $self->check_for_fork();

    # If no stage was set we do not want to clear this, root stages need to
    # preserve the preloads
    return unless $self->{+STAGE};

    # From Runner
    delete $self->{+STAGE};
    delete $self->{+STATE};
    delete $self->{+LAST_TIMEOUT_CHECK};

    return;
}

sub run_stage {
    my $self = shift;
    my ($stage) = @_;

    $self->{+STAGE} = $stage;
    $self->state->stage_ready($stage);

    while (1) {
        # Service the runner.socket from the root process only: forked stage
        # children inherit the listen FD but must not accept on it.
        if ($self->{+ROOTPID} == $$) {
            $self->service_io;
            $self->service_tick;
        }

        next if $self->run_job();

        next if $self->wait();

        last if $self->end_test_loop();

        sleep($self->{+WAIT_TIME}) if $self->{+WAIT_TIME};
    }

    $self->state->stage_down($stage);

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

    my $spawn_time;

    my $pid;
    my $via = $job->via();
    if ($via) {
        require(mod2file($1)) if !defined(&{$via}) && $via =~ m/^(.+)::[^:]+$/;

        $spawn_time = time();
        $pid        = $self->$via($job);
        $job->set_pid($pid);
        $self->watch($job);
    }
    else {
        $spawn_time = time();
        $self->spawn($job);
        $pid = $job->pid;
    }

    my $json_data = $job->TO_JSON();
    $json_data->{stamp} = $spawn_time;
    $run->jobs->write($json_data);

    return $pid;
}

sub orphaned {
    my $self = shift;

    # A persistent runner whose workdir or persistence file has been removed has
    # lost its owner (a `yath stop`, or a starter that died and got cleaned up).
    # Nothing will ever drive it again, so shut down instead of idling forever
    # and respawning preload stages. Already-signalled shutdowns are left alone.
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
    if (!$self->{+STAGE} || $self->{+STAGE} eq 'default' || $self->{+STAGE} eq 'base') {
        $self->{+RESPAWN_RUNNER_CALLBACK}->()
            if $self->preloader->check($state) || ($self->{+SIGNAL} && $self->{+SIGNAL} eq 'HUP');
    }

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

        my $timed_out = 0;
        if ( !$exit && ref $self->{run_reached_timeout} && $self->{run_reached_timeout}->{ $task->{job_id} } ) {
            delete $self->{run_reached_timeout}->{ $task->{job_id} };
            $timed_out = 1;
        }

        if (($exit || $timed_out) && $proc->is_try < ($proc->retry // 0) ) {
            $self->state->retry_task($task->{job_id});
            push @args => 'will-retry';
        }
        else {
            $self->state->stop_task($task->{job_id});
        }

        if(my $bail = $exit ? $proc->bailed_out : 0) {
            print "$$ $0 BAIL-OUT detected: $bail\n";
            if ($self->settings->runner->abort_on_bail) {
                print "$$ $0 Aborting the test run...\n";
                $self->state->halt_run($task->{run_id});
            }
        }
    }
    elsif ($proc->isa('Test2::Harness2::Runner::Preloader::Stage')) {
        my $stage = $proc->name;

        if ($exit != 0) {
            my $e = parse_exit($exit);
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

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner - Base class for test runners

=head1 DESCRIPTION

This module does the heavy lifting of running all the tests.

You should never need to create an instance of the runner yourself. In most
cases the runner module is exposed via a callback or a plugin affordance.

=head1 PUBLIC METHODS

=head2 FROM SETTINGS

These are attributesd with values set from the L<Getopt::Yath::Settings>
instance created from command line arguments.

See L<App::Yath2::Options::Runner> for the most up to date documentation on
these.

=over 4

=item $runner->includes

=item $runner->tlib

=item $runner->lib

=item $runner->blib

=item $runner->unsafe_inc

=item $runner->use_fork

=item $runner->preloads

=item $runner->preload_threshold

=item $runner->switches

=item $runner->cover

=item $runner->event_timeout

=item $runner->post_exit_timeout

=back

=head2 FROM CONSTRUCTION

These attributes are set when the runner is created.

=over 4

=item $path = $runner->dir

Path to the working directory.

=item $settings = $runner->settings

The L<Getopt::Yath::Settings> instance.

=item $coderef = $runner->fork_job_callback

Callback used to spawn new tests via fork.

=item $coderef = $runner->respawn_runner_callback

Callback to restart the runner process.

=item $bool = $runner->monitor_preloads

True if preloads should be watched for changes.

=item $int = $runner->jobs_todo

A count of total jobs to run. This will always be 0 in a persistent runner.

=back

=head2 OTHER PUBLIC METHODS

If a method is not documented here then it is an implementation detail and you
should not use it.

=over 4

=item $class = $runner->job_class

Class for new test jobs.

=item $preload = $runner->preloader

Get the L<Test2::Harness2::Runner::Preloader> instance.

=item $state = $runner->state

Get the L<Test2::Harness2::Runner::State> instance.

=item @list = $runner->all_libs

Get all the libs that should be added to @INC by default. Note that specific
runs and even specific tests can have custom paths on top of these.

=back

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
