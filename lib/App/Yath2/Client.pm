package App::Yath2::Client;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use POSIX();

use Test2::Harness2::Runner();
use Test2::Harness2::Runner::Client();
use Test2::Harness2::Runner::Subscriber();
use Test2::Harness2::Util qw/runner_events_file/;
use Test2::Harness2::Util::IPC qw/run_cmd/;

use App::Yath2::RunPlan();

use Test2::Harness2::Util::HashBase qw{
    <workdir
    <settings
    <mode
    +liveness_check
    +spawn_args
    +monitor_preloads
    +on_signal

    <runner_pid
    +owns_runner
    +runner_exited
    +sigs_installed
    <signal

    +run_plan
    +finder_args
    +run_id
    +pending_tasks

    +submitter
    +subscriber
};

# The runner-lifecycle modes the client supports (CL-1). The command picks one at
# construction; everything else (reaping, signal trapping, discovery) follows.
sub MODE_TRANSIENT() { 'transient' }
sub MODE_ATTACH()    { 'attach' }
sub MODE_START()     { 'start' }

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Client - The bridge between C<App::Yath2> and the C<Test2::Harness2>
runner socket: owns the runner lifecycle, the finders/job-spec building, the
submit + subscribe transports, and first-class state queries over the runner
state mirror.

=head1 DESCRIPTION

The C<test> / C<run> / C<start> commands all talk to a runner over its unix
socket (C<runner.socket>): they find and order the test files, build the run and
its task list, spawn or discover the runner, submit the run + tasks, and (for
C<test>/C<run>) subscribe to the runner's canonical state to drive rendering.
This object is the one bridge that owns that plumbing, so the command classes
stay thin and the transient-vs-persistent difference is a B<mode>, not a
command-inheritance tree.

It owns three concerns:

=over 4

=item Runner lifecycle (a mode enum)

=over 4

=item *

B<transient> -- spawn the collector-wrapped runner, own it, reap it, and trap +
forward C<INT>/C<TERM>/C<HUP> to the runner's process group. Used by C<yath
test>.

=item *

B<attach> -- discover a pre-existing persistent runner (its pid is supplied by
the caller from the discovery file), check liveness with C<kill(0)>, and never
reap it. Used by C<yath run>.

=item *

B<start> -- spawn the daemon runner and return its pid; the caller records the
discovery state. Used by C<yath start>.

=back

=item Finders + job-spec building

It owns an L<App::Yath2::RunPlan> (file discovery, plugin sort hooks, per-file
task construction) and submits the resulting run + tasks over the socket.

=item State queries

First-class accessors over the mirrored L<Test2::Harness2::Runner::Monitor>
(L</jobs_in_state>, L</events_file_for>, the run/job rollup) so callers stop
drilling C<< client->subscriber->monitor->... >>.

=back

It wraps the two lower-level transports shipped with the runner --
L<Test2::Harness2::Runner::Client> (one-shot request submission) and
L<Test2::Harness2::Runner::Subscriber> (snapshot-plus-forwarded-transitions
mirror).

=head1 SYNOPSIS

    my $client = App::Yath2::Client->new(
        workdir    => $workdir,
        settings   => $settings,
        mode       => 'transient',
        spawn_args => [@plugin_spawn_args],
        on_signal  => sub { my $sig = shift; $render_loop->signal($sig) },
    );

    # Lifecycle:
    $client->install_signal_handlers;       # transient + attach (no-op in start)
    my $job_count = $client->populate;      # find + build tasks
    $client->start_runner(jobs_todo => $job_count);
    $client->submit_queue;
    $client->terminate_queue;               # end_queue, transient only

    # Subscription transport (a Test2::Harness2::Runner::Subscriber):
    my $sub = $client->connect_subscriber;

    # State queries over the mirror:
    my @done = $client->jobs_in_state('done');
    my $file = $client->events_file_for($uuid);

    # Teardown:
    $client->wait_for_runner;
    $client->remove_signal_handlers;

=head1 ATTRIBUTES

=over 4

=item $dir = $client->workdir

The working directory holding C<runner.socket>.

=item $settings = $client->settings

The settings object (drives the run plan and the transient/start runner command).

=item $mode = $client->mode

The runner-lifecycle mode: C<transient>, C<attach>, or C<start>.

=item runner_pid

=item $pid = $client->runner_pid

The runner process id (spawned in transient/start mode, supplied by the caller in
attach mode).

=item run_id

=item $id = $client->run_id

The id of the run this client built (after L</populate>).

=item signal

=item $sig = $client->signal

The signal the client last caught (in transient mode), or C<undef>.

=back

=cut

sub init ($self) {
    croak "'workdir' is a required attribute" unless defined $self->{+WORKDIR};

    my $mode = $self->{+MODE} //= MODE_TRANSIENT;
    croak "Invalid mode '$mode'"
        unless $mode eq MODE_TRANSIENT || $mode eq MODE_ATTACH || $mode eq MODE_START;

    return;
}

=head1 PUBLIC METHODS

=head2 Runner lifecycle

=over 4

=item install_signal_handlers

=item $client->install_signal_handlers

Install C<INT>/C<HUP>/C<TERM> handlers that forward to L</handle_signal>. Both the
foreground modes install them: C<transient> (C<yath test>) forwards the signal to
the owned runner's process group, C<attach> (C<yath run>) halts just this run over
the socket and lets the command's C<stop()> run its graceful teardown (flush
renderers/logs, reset the terminal, drain the DB loggers). Idempotent and a no-op
in C<start> mode (the daemon detaches and installs nothing here).

=item $client->remove_signal_handlers

Remove the handlers L</install_signal_handlers> set. Idempotent.

=cut

sub install_signal_handlers ($self) {
    # Both foreground modes trap: transient forwards to the owned runner's pgroup,
    # attach halts just this run over the socket and lets stop() flush/reset/drain.
    # start mode daemonizes and installs nothing.
    return if $self->{+MODE} eq MODE_START;
    return if $self->{+SIGS_INSTALLED};
    $self->{+SIGS_INSTALLED} = 1;

    for my $sig (qw/INT HUP TERM/) {
        $SIG{$sig} = sub { $self->handle_signal($sig) };
    }

    return;
}

sub remove_signal_handlers ($self) {
    return unless $self->{+SIGS_INSTALLED};
    $self->{+SIGS_INSTALLED} = 0;

    delete $SIG{$_} for qw/INT HUP TERM/;

    return;
}

=item handle_signal

=item $client->handle_signal($sig)

Handle a caught signal: forward it to the caller's signal hook (so the render loop
stops and the renderers flush), then act by mode. In C<transient> mode forward the
signal to the owned runner's process group (tearing down its job children). In
C<attach> mode NEVER signal the shared persistent runner -- ask it to halt just
this run over the socket for promptness (the owner-disconnect sweep aborts it
regardless); the graceful teardown (renderer/log flush, terminal reset, DB-logger
drain) then runs in the command's C<stop()>. In both modes the signal is recorded
so a second signal exits immediately. The caller checks L</signal> after the render
loop returns to do its caught-signal shutdown.

=cut

sub handle_signal ($self, $sig) {
    my $on_signal = $self->{+ON_SIGNAL};
    $on_signal->($sig) if $on_signal;

    if ($self->{+MODE} eq MODE_ATTACH) {
        # The persistent runner is shared and NOT ours to signal. Ask it to halt just
        # THIS run over the socket for promptness (the owner-disconnect sweep aborts
        # it regardless); the graceful teardown runs in the command's stop().
        print STDERR "\nCaught SIG$sig, halting this run and cleaning up...\n";
        eval { $self->halt_run; 1 };
    }
    else {
        # Transient: forward to the owned runner's process group so it tears down its
        # job children.
        print STDERR "\nCaught SIG$sig, forwarding signal to child processes...\n";
        $self->signal_runner($sig);
    }

    if ($self->{+SIGNAL}) {
        print STDERR "\nSecond signal ($self->{+SIGNAL} followed by $sig), exiting now without waiting\n";
        exit 1;
    }

    $self->{+SIGNAL} = $sig;

    return;
}

=item $pid = $client->start_runner(%args)

Bring the runner into being for this client's mode and return its pid:

=over 4

=item *

B<transient> -- spawn the collector-wrapped runner (the C<yath test> runner under
a non-test L<Test2::Collector> so its stdout/stderr/exit become first-class
events). The client owns this child and reaps/signals it.

=item *

B<start> -- spawn the daemon runner the same way and return its pid; the caller
records the discovery state. C<%args> (e.g. C<persist>, C<monitor_preloads>,
C<jobs_todo>) are threaded into the runner command. C<daemon> controls whether the
process group is detached.

=item *

B<attach> -- a no-op (the runner already exists); set L</runner_pid> with
L</attach_runner> instead.

=back

=cut

sub start_runner ($self, %args) {
    return if $self->{+MODE} eq MODE_ATTACH;

    my $settings = $self->{+SETTINGS} or croak "'settings' is required to start a runner";
    my $dir      = $self->{+WORKDIR};

    $args{monitor_preloads} //= $self->{+MONITOR_PRELOADS} // 0;

    my @prof;
    push @prof => '-d:NYTProf' if $settings->runner->nytprof;

    # The runner command is the exec target of a non-test collector
    # (Test2::Harness2::Runner->start_collected): the runner's stdout/stderr/exit
    # become first-class, timestamped harness events in runner-events.jsonl.zst --
    # the same wire format and reader path as job events.
    my @runner_cmd = (
        $^X, @prof, @{$self->{+SPAWN_ARGS} // []}, $settings->harness->script,
        (map { "-D$_" } @{$settings->harness->dev_libs}),
        '--no-scan-plugins',    # Do not preload any plugin modules
        runner => $dir,
        %args,
    );

    my $command = Test2::Harness2::Runner->start_collected(\@runner_cmd, runner_events_file($dir));

    # The command owns exactly this one child, spawned on the fork-exec run_cmd
    # primitive and reaped/signalled here. start_collected detaches the daemon
    # collector parent's stdout/stderr itself, so a daemon does not hold the caller
    # pipe open. Only the 'start' mode produces a daemon (and only the start
    # command's runner group carries a 'daemon' option), so the daemon split is
    # gated on the mode; the transient runner always runs in this command's group.
    my $no_set_pgrp = 1;
    $no_set_pgrp = !$settings->runner->daemon if $self->{+MODE} eq MODE_START;

    my $pid = run_cmd(
        @prof ? (env => {NYTPROF => 'start=no:addpid=1'}) : (),
        no_set_pgrp => $no_set_pgrp,
        command     => $command,
    );

    $self->{+RUNNER_PID}    = $pid;
    $self->{+OWNS_RUNNER}   = 1;
    $self->{+RUNNER_EXITED} = 0;

    return $pid;
}

=item attach_runner

=item $client->attach_runner($pid)

Record the pid of a pre-existing persistent runner (attach mode). The client never
reaps this process; liveness is a plain C<kill(0)>.

=cut

sub attach_runner ($self, $pid) {
    $self->{+RUNNER_PID}  = $pid;
    $self->{+OWNS_RUNNER} = 0;

    return $pid;
}

=item $bool = $client->owns_runner

True when this client spawned (and is responsible for reaping) the runner.

=item $client->reap_runner

Non-blocking reap of the one owned runner child. Records that the runner has gone
once it is reaped. A no-op when the client does not own the runner.

=cut

sub owns_runner ($self) { return $self->{+OWNS_RUNNER} ? 1 : 0 }

sub reap_runner ($self) {
    return if $self->{+RUNNER_EXITED};

    my $pid = $self->{+RUNNER_PID};
    return unless $pid && $self->{+OWNS_RUNNER};

    local $?;
    my $got = waitpid($pid, POSIX::WNOHANG());
    $self->{+RUNNER_EXITED} = 1 if $got == $pid || $got == -1;

    return;
}

=item runner_gone

=item $bool = $client->runner_gone

True once the runner is no longer alive. For an owned (transient) runner this
reaps and checks the exit; for an attached (persistent) runner it is a C<kill(0)>
liveness probe. With no runner pid at all it returns true.

=cut

sub runner_gone ($self) {
    my $pid = $self->{+RUNNER_PID} or return 1;

    if ($self->{+OWNS_RUNNER}) {
        $self->reap_runner;
        return $self->{+RUNNER_EXITED} ? 1 : 0;
    }

    return kill(0, $pid) ? 0 : 1;
}

=item $client->wait_for_runner

Block until the owned runner has been reaped. A no-op when the client does not own
the runner.

=cut

sub wait_for_runner ($self) {
    my $pid = $self->{+RUNNER_PID};
    return unless $pid && $self->{+OWNS_RUNNER};
    return if $self->{+RUNNER_EXITED};

    local $?;
    waitpid($pid, 0);
    $self->{+RUNNER_EXITED} = 1;

    return;
}

=item $client->signal_runner($sig)

Forward a signal (default C<TERM>) to the owned runner; it tears down its own job
children. A no-op when the client does not own the runner.

=back

=cut

sub signal_runner ($self, $sig = 'TERM') {
    my $pid = $self->{+RUNNER_PID};
    return unless $pid && $self->{+OWNS_RUNNER};

    kill($sig, $pid);

    return;
}

=head2 Finders + job-spec building

=over 4

=item $plan = $client->run_plan

The L<App::Yath2::RunPlan> this client builds from. Built (and cached) from the
settings + workdir.

=item build_run

=item $run = $client->build_run

The L<Test2::Harness2::Run> for this client's plan (creates the run dir as a side
effect on first use).

=item populate

=item $count = $client->populate

Find + order the test files and build the task list via the run plan. Stashes the
run id and tasks on the client and returns the job count. The run + tasks are
B<not> submitted here (submission is over the socket, after the runner binds).

=item $id = $client->run_id

The id of the run built by L</populate> (or L</build_run>).

=item $tasks = $client->pending_tasks

The task list produced by L</populate> (an arrayref).

=cut

sub run_plan ($self) {
    return $self->{+RUN_PLAN} //= App::Yath2::RunPlan->new(
        settings    => $self->{+SETTINGS},
        workdir     => $self->{+WORKDIR},
        finder_args => $self->{+FINDER_ARGS} // [],
    );
}

sub build_run ($self) { return $self->run_plan->run }

sub populate ($self) {
    my $plan = $self->run_plan;

    my $job_count = $plan->populate();

    $self->{+RUN_ID}        = $plan->run_id;
    $self->{+PENDING_TASKS} = $plan->tasks;

    return $job_count;
}

sub run_id ($self) { return $self->{+RUN_ID} //= $self->run_plan->run_id }

sub pending_tasks ($self) { return $self->{+PENDING_TASKS} //= [] }

=item $client->submit_queue

Submit the run, its tasks, and the run terminator (C<stop_run>) to the runner over
the socket. Used by both the transient and persistent paths.

=cut

sub submit_queue ($self) {
    my $run       = $self->build_run;
    my $plugins   = $self->{+SETTINGS}->harness->plugins;
    my $submitter = $self->submitter;

    $submitter->queue_run($run->queue_item($plugins));

    $submitter->queue_task($_) for @{$self->pending_tasks};

    $submitter->stop_run($run->run_id);

    return;
}

=item $client->terminate_queue

Send the end-of-queue request (the transient runner's shutdown signal). A no-op in
attach mode: the persistent runner serves many runs and is not shut down per run.

=back

=cut

sub terminate_queue ($self) {
    return if $self->{+MODE} eq MODE_ATTACH;
    $self->submitter->end_queue;
    return;
}

=head2 State queries

=over 4

=item $mon = $client->monitor

The local mirror of the runner's canonical state (the subscriber's monitor), or
C<undef> until L</connect_subscriber> has run.

=item @uuids = $client->collectors_in_status($status)

The collector uuids currently in C<$status> (C<running> / C<complete> /
C<finalized>) in the mirror.

=item jobs_in_state

=item @job_ids = $client->jobs_in_state($state)

The job ids the runner has reported in C<$state> (C<dispatched> / C<running> /
C<done> / C<aborted>) in the mirror.

=item events_file_for

=item $path = $client->events_file_for($uuid)

The on-disk events file path for one collector uuid in the mirror, or C<undef>.

=item $bool = $client->run_done($run_id)

True once the runner has announced C<$run_id> finished (defaults to this client's
own L</run_id>).

=item $list = $client->run_health

The suite-level health failures the runner reported (post-pass collector
failures); an arrayref of C<< {run_id, reason} >> records.

=back

=cut

sub monitor ($self) {
    my $sub = $self->{+SUBSCRIBER} or return undef;
    return $sub->monitor;
}

sub collectors_in_status ($self, $status) {
    my $mon = $self->monitor or return ();
    return grep { ($mon->status($_) // '') eq $status } $mon->collectors;
}

sub jobs_in_state ($self, $state) {
    my $mon = $self->monitor or return ();
    return grep {
        my $job = $mon->job($_);
        $job && defined($job->{state}) && $job->{state} eq $state;
    } $mon->job_ids;
}

sub events_file_for ($self, $uuid) {
    my $mon = $self->monitor or return undef;
    return $mon->events_file($uuid);
}

sub run_done ($self, $run_id = undef) {
    my $mon = $self->monitor or return 0;
    $run_id //= $self->{+RUN_ID};
    return 0 unless defined $run_id;
    return $mon->run_done($run_id);
}

sub run_health ($self) {
    my $mon = $self->monitor or return [];
    return $mon->run_health;
}

=head2 Transports

=over 4

=item liveness_check

=item $coderef = $client->liveness_check

The check (passed to the submission client) that returns true while the runner is
alive, so the client stops trying if the runner died before it ever accepted. When
not supplied at construction it defaults to L</runner_gone> (transient owned-runner
reap, or attach C<kill(0)>).

=item $submitter = $client->submitter

The run/task/end-queue submission transport: a (cached)
L<Test2::Harness2::Runner::Client> bound to C<< $workdir/runner.socket >> and given
the L</liveness_check>. Exposes C<queue_run>, C<queue_task>, C<stop_run>,
C<end_queue>, C<halt_run>, and the stage-reporting requests.

=item $hash = $client->reload_state

Query the runner's canonical reload state (per-stage source files with reload
errors/warnings) over the socket. Returns the reload-state hash (possibly empty)
or C<undef> if the runner could not be reached.

=item $hash = $client->status

Query the runner's live scheduling status over the socket (used by C<yath
status>/C<yath ps>). Returns the status hash, or C<undef> if the runner could not
be reached.

=item $running = $client->truncate

Ask the runner to truncate its queue (abort pending work) and return the
still-running jobs for the caller to signal (used by C<yath abort>). Returns the
running-job arrayref, or C<undef> if the runner could not be reached.

=item $list = $client->resources

Query the runner's live resource status over the socket (used by C<yath
resources>). Returns an arrayref of C<< {class, lines} >> records, or C<undef> if
the runner could not be reached.

=item $reply = $client->ping

A no-side-effect liveness round-trip over the socket (used by C<yath ping>).
Returns the runner's ack hashref (C<< {ok, pid, stamp} >>), or C<undef> if the
runner could not be reached.

=item $client->halt_run

Ask the runner to halt this client's run over the socket (the caught-signal
shutdown path).

=item $sub = $client->subscriber

The subscription transport, or C<undef> until L</connect_subscriber> has run.

=item connect_subscriber

=item $sub = $client->connect_subscriber(%params)

Build a L<Test2::Harness2::Runner::Subscriber>, attempt the subscription exactly
once, and cache + return it; returns C<undef> (with a warning) if the runner never
bound/accepted the socket (e.g. a broken preload that killed the runner during
startup) so the caller can fall back. C<%params> are threaded into the subscriber
constructor (notably a C<run_id> for a run-scoped subscription).

=back

=cut

sub liveness_check ($self) {
    return $self->{+LIVENESS_CHECK} //= sub { $self->runner_gone ? 0 : 1 };
}

sub submitter ($self) {
    return $self->{+SUBMITTER} //= Test2::Harness2::Runner::Client->new(
        workdir        => $self->{+WORKDIR},
        liveness_check => $self->liveness_check,
    );
}

sub reload_state ($self) { return $self->submitter->reload_state }

sub status ($self) { return $self->submitter->status }

sub truncate ($self) { return $self->submitter->truncate }

sub resources ($self) { return $self->submitter->resources }

sub ping ($self) { return $self->submitter->ping }

sub halt_run ($self) { return $self->submitter->halt_run($self->{+RUN_ID}) }

sub subscriber ($self) { return $self->{+SUBSCRIBER} }

sub connect_subscriber ($self, %params) {
    my $sub = Test2::Harness2::Runner::Subscriber->new(
        workdir        => $self->{+WORKDIR},
        # Fast-fail the subscribe connect if the runner died after binding the
        # socket, instead of stalling the full CONNECT_TIMEOUT. The eval below
        # turns _connect's "Runner is gone" croak into the warn+undef fallback.
        # (TODO-134 finding 108)
        liveness_check => $self->liveness_check,
        %params,
    );

    my $ok = eval { $sub->subscribe; 1 };
    warn "Could not subscribe to runner socket: $@" unless $ok;

    return $self->{+SUBSCRIBER} = $ok ? $sub : undef;
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
