package Test2::Harness2::Runner::Role::Service::Handlers;
use v5.38;

our $VERSION = '2.000000';

use Time::HiRes qw/time/;

use Test2::Collector::Util::Zstd qw/compress_blob/;
use Test2::Harness2::Util::JSON qw/encode_json/;

use Test2::Harness2::Runner::Monitor();
use Test2::Harness2::Runner::StatusReport();

use Role::Tiny;

requires qw/state/;

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::Role::Service::Handlers - The runner's socket request
handlers and transition hub.

=head1 DESCRIPTION

This role carries the request/response and transition-channel half of
L<Test2::Harness2::Runner>. It is the set of C<request_handler_*> methods the
L<Test2::Harness2::Role::Service> loop dispatches to (run/task/spawn submission,
stage outcome reports, status/abort/reload queries, subscription), plus the
transition hub that folds collector transitions into the canonical
L<Test2::Harness2::Runner::Monitor> and forwards both folded and
runner-originated mutations to subscribers.

It is composed into the runner alongside L<Test2::Harness2::Role::Service> and
L<Test2::Harness2::Runner::Role::Scheduler>; every method here is a method on the
runner C<$self> and shares its hashref slots and its other composed methods
(C<state>, C<forward_frame>, C<add_subscriber>).

=head1 SYNOPSIS

    package Test2::Harness2::Runner;
    use Role::Tiny::With;
    with 'Test2::Harness2::Runner::Role::Service::Handlers';

=head1 PUBLIC METHODS

=over 4

=item $monitor = $self->monitor

Get the L<Test2::Harness2::Runner::Monitor> instance: the runner-side fold of
the collector transition channel.

=item $self->service_transition($payload, $frame, $conn)

L<Test2::Harness2::Role::Service> hands every transition frame here; fold it into
the monitor and forward it (verbatim) to that run's subscribers.

=item $self->announce_job($job_id, $state, %extra)

Fold and forward a runner-originated job mutation (dispatched / running / retry /
done) so a subscriber's mirror folds it identically.

=item $self->announce_run($run_id)

Fold and forward a runner-originated run-completion mutation.

=item $self->record_job_pid($job_id, $pid)

Record a started job's pid in the runner's in-memory map.

=item $resp = $self->request_handler_E<lt>typeE<gt>($payload, $conn)

The socket request handlers; see the inline documentation for each.

=back

=cut

# Run submission moved onto runner.socket (chunk 5c): a transient `yath test`
# command no longer constructs its own State; it connects to runner.socket and
# sends one-way request frames. The runner receives them here and enqueues them
# through the canonical State's public queue_* methods, which apply each action
# in-process. The runner is the sole owner of its scheduling state -- it dispatches
# tasks to its stage services over sockets and folds their outcomes back in
# (A2 retired dispatch.jsonl entirely; there is no shared action log or file
# reader). The persistent run/spawn/abort path submits the same way over the
# socket.
#
# These are one-way requests: the role's _service_conn sends no reply when a
# handler returns undef. Ordering is preserved because the command sends them
# over a single connection and the FrameBuffer drains frames in order.
sub request_handler_queue_run {
    my $self = shift;
    my ($payload) = @_;
    $self->state->queue_run($payload->{run});
    return undef;
}

sub request_handler_queue_task {
    my $self = shift;
    my ($payload) = @_;
    $self->state->queue_task($payload->{task});
    return undef;
}

sub request_handler_stop_run {
    my $self = shift;
    my ($payload) = @_;
    $self->state->stop_run($payload->{run_id});
    return undef;
}

# Chunk 6.1-2: `yath spawn` submits its spawn over runner.socket (instead of the
# in-process dispatch.jsonl State it used while gated). The runner folds it into
# the canonical State, which the (persistent) stages pick up to launch the script.
#
# Review P2: this is acknowledged (two-way). The command then blocks on a worker
# tempfile (the legitimate wait while the spawned program runs) whose own timeout
# is long; if the runner cannot route the spawn -- it is not the state hub, or the
# target stage does not exist / is not a live ready preload service -- the command
# would otherwise learn nothing until that long wait expired. So we resolve the
# spawn's stage and check stage readiness synchronously and return a negative ack
# in that case, letting `yath spawn` fail promptly with a clear diagnostic. On a
# live stage we queue the spawn and ack success; the stage launches it and the
# tempfile wait proceeds as the legitimate run of the spawned program.
sub request_handler_queue_spawn {
    my $self = shift;
    my ($payload) = @_;

    return {ok => 0, error => 'not the runner state hub'}
        unless $self->{'rootpid'} == $$;

    my $spawn = $payload->{spawn} // {};
    my ($stage, $ready) = $self->state->spawn_stage_ready($spawn);

    return {ok => 0, stage => $stage, error => "No live preload stage '$stage' is available to run the spawn"}
        unless $ready;

    $self->state->queue_spawn($spawn);

    return {ok => 1, queued => 1, stage => $stage};
}

sub request_handler_end_queue {
    my $self = shift;
    $self->state->end_queue();
    return undef;
}

# A transient command that caught a signal asks the runner to halt the run over
# the socket (chunk 5c). The runner stops scheduling tasks for the run and
# terminates its own job children through its normal signal/stop path; the command
# does not reconstruct state to kill individual job pids.
sub request_handler_halt_run {
    my $self = shift;
    my ($payload) = @_;
    $self->state->halt_run($payload->{run_id});
    return undef;
}

# Chunk 5d: a forked transient preload stage receives dispatched jobs on its own
# preload-<stage>.socket. The runner's in-process scheduler connects out and sends
# the already-resolved task (with the resources merged in) plus the run definition;
# the stage delegate queues it and the stage's run loop forks it from the preloaded
# interpreter. One-way: the runner does not read a reply.
sub request_handler_run_task {
    my $self = shift;
    my ($payload) = @_;
    $self->state->enqueue_task($payload->{task}, $payload->{run});
    return undef;
}

# Chunk 5d: a stage reports a finished dispatched job back to the runner over
# runner.socket so the runner's canonical scheduler state releases the slot and
# resources (stop) or re-queues it for dispatch (retry). The retry-vs-stop decision
# is made by the stage that reaped the job (it owns the proc / is_try / verdict);
# here we only fold the outcome into state. One-way.
sub request_handler_stop_task {
    my $self = shift;
    my ($payload) = @_;
    $self->state->stop_task($payload->{job_id});
    delete $self->{'job_pids'}->{$payload->{job_id}};
    # Chunk 5f: a stage-reported job finishing is a runner-originated state
    # mutation; forward it to subscribers so their mirror releases the job.
    $self->announce_job($payload->{job_id}, 'done');
    return undef;
}

sub request_handler_retry_task {
    my $self = shift;
    my ($payload) = @_;
    $self->state->retry_task($payload->{job_id});
    delete $self->{'job_pids'}->{$payload->{job_id}};
    $self->announce_job($payload->{job_id}, 'retry');
    return undef;
}

# Chunk 5d: a monitored stage forwards a reload/monitor notification so the
# runner's reload state (diagnostics) stays current without a shared file. One-way.
sub request_handler_reload {
    my $self = shift;
    my ($payload) = @_;
    $self->state->reload($payload->{stage}, $payload->{data});
    return undef;
}

# Chunk 6.1-3: the persistent `yath run` command checks the runner's reload state
# (per-stage source-file reload errors/warnings) before starting a run, so it can
# abort or prompt. It used to read this by constructing an observe-mode State that
# polled dispatch.jsonl; now it asks the runner over the socket. Two-way: returns
# the canonical reload_state hash. Only the root runner is the state authority.
sub request_handler_reload_state {
    my $self = shift;

    return {ok => 0, error => 'not the runner state hub'}
        unless $self->{'rootpid'} == $$;

    return {ok => 1, reload_state => $self->state->reload_state // {}};
}

# Chunk 6.1-2: the persistent `status`/`ps`/`abort` commands ask the runner for
# its live scheduling state over runner.socket instead of reading dispatch.jsonl
# (observe-mode State) + jobs.jsonl (job pids). The runner is the state authority;
# it builds a serializable report from its canonical State plus its in-memory
# job-pid map (it knows each job's pid when it forks it, or when a stage reports
# the pid of a job the stage forked). Two-way: returns the report hash.
sub request_handler_status {
    my $self = shift;

    return {ok => 0, error => 'not the runner state hub'}
        unless $self->{'rootpid'} == $$;

    my $report = Test2::Harness2::Runner::StatusReport->new(
        state    => $self->state,
        job_pids => $self->{'job_pids'},
    );

    return {ok => 1, status => $report->build};
}

# Chunk 6.1-2: a transient/persistent root command asks the runner to truncate
# the queue (abort) over the socket, replacing the observe-State truncate the
# `abort` command used to do by writing dispatch.jsonl directly. The runner
# truncates its own canonical state. Two-way: returns the kill list (the
# still-running jobs and their pids) so the command can signal them. The runner
# does not signal the jobs itself -- `abort` deliberately leaves the runner alive
# and only INT's the running tests, matching the historical behavior.
sub request_handler_truncate {
    my $self = shift;

    return {ok => 0, error => 'not the runner state hub'}
        unless $self->{'rootpid'} == $$;

    my $report = Test2::Harness2::Runner::StatusReport->new(
        state    => $self->state,
        job_pids => $self->{'job_pids'},
    );

    my $running = $report->build->{running};

    $self->state->truncate;

    return {ok => 1, running => $running};
}

# A2: the `resources` command asks the runner for its live resource status over
# runner.socket instead of constructing an observe-mode State that polled
# dispatch.jsonl. The runner owns the live resource objects (in its canonical
# State); it renders each resource's status_lines here -- the resource objects do
# not serialize, but their already-formatted status text does -- and returns the
# rendered text per resource so the command can print it verbatim. Two-way:
# returns the rendered resource list. Only the root runner is the state authority.
sub request_handler_resources {
    my $self = shift;

    return {ok => 0, error => 'not the runner state hub'}
        unless $self->{'rootpid'} == $$;

    my @out;
    for my $resource (@{$self->state->resources // []}) {
        my $lines = $resource->status_lines;
        next unless defined $lines && length $lines;
        push @out => {class => ref($resource), lines => $lines};
    }

    return {ok => 1, resources => \@out};
}

# Chunk 6.1-2: a forked preload stage forks a dispatched test job from its
# preloaded interpreter, so the stage -- not the runner -- knows the job's pid.
# It reports the pid back over runner.socket so the runner's job-pid map (used by
# the status/ps/abort report) is complete without a jobs.jsonl file. One-way.
sub request_handler_job_pid {
    my $self = shift;
    my ($payload) = @_;
    $self->record_job_pid($payload->{job_id}, $payload->{pid});
    return undef;
}

# Record a started job's pid in the runner's in-memory map (the runner's own
# forked jobs at run_job, a stage's forked jobs via the job_pid request). Cleared
# when the job's task stops so a future job that reuses a pid does not inherit a
# stale entry.
sub record_job_pid {
    my $self = shift;
    my ($job_id, $pid) = @_;

    return unless $self->{'rootpid'} == $$;
    return unless defined $job_id && defined $pid;

    $self->{'job_pids'}->{$job_id} = $pid;

    return;
}

# Chunk 5d: a transient stage reports it has bound its socket and is ready to be
# scheduled (or is going down at shutdown). The runner folds this into the same
# stage-readiness state its scheduler's _stage_order already gates on, replacing
# the dispatch.jsonl stage_ready/stage_down actions for the transient path. One-way.
sub request_handler_stage_ready {
    my $self = shift;
    my ($payload) = @_;
    $self->state->stage_ready($payload->{stage});
    return undef;
}

sub request_handler_stage_down {
    my $self = shift;
    my ($payload) = @_;
    $self->state->stage_down($payload->{stage});
    return undef;
}

# Chunk 19.1: the preload-root process (Test2::Harness2::Preload) dials the runner
# and asks for the preload list -- the runner no longer loads the preload
# libraries itself; the preload root does. Return the resolved -P/--preload module
# specs the user passed (the runner's `preloads`). Two-way. Only the root runner is
# the state hub.
sub request_handler_get_preload_list {
    my $self = shift;

    return {ok => 0, error => 'not the runner state hub'}
        unless $self->{'rootpid'} == $$;

    return {ok => 1, preloads => [@{$self->preloads // []}]};
}

# Chunk 19.1: the preload-root loads the preload libraries, builds the stage map
# (each stage's eager fan-out + which is default), and reports it here so the
# runner knows which stages to expect without loading any preload itself
# (19_spec.md §6.3). The runner stores it (the gate that makes preload-task
# dispatch wait on it lands with the preload-root-driven dispatch in 19.2; storing
# it now is additive and does not change the existing in-runner dispatch path).
# One-way is enough, but we ack so the preload root can confirm receipt. Only the
# root runner is the state hub.
sub request_handler_set_stage_data {
    my $self = shift;
    my ($payload) = @_;

    return {ok => 0, error => 'not the runner state hub'}
        unless $self->{'rootpid'} == $$;

    $self->{'reported_stage_data'} = $payload->{stage_data} // {};

    return {ok => 1};
}

# The stage map the preload root reported (chunk 19.1), or undef before it has
# arrived. `has_reported_stage_data` is the readiness predicate the 19.2
# dispatch gate will consult; in 19.1 it is exposed but does not yet gate the
# existing in-runner dispatch path.
sub reported_stage_data     { $_[0]->{'reported_stage_data'} }
sub has_reported_stage_data { defined $_[0]->{'reported_stage_data'} ? 1 : 0 }

# Chunk 5e: the runner is the hub of the transition channel. Every non-runner
# collector (each test job, each transient preload stage, any aux collector)
# connects its reporter to runner.socket and streams its transitions here; the
# runner folds them into this canonical in-process state object (uuid, name,
# category, events_file, try, run_uuid, status, failing/diagnosing, final_state,
# plus drain-on-call change-lists). The runner's OWN collector (the one
# App::Yath2::Command::test::start_runner wraps it in) does NOT report here -- it
# records to its own events file only; the runner is the hub, not its own peer.
# This state is infrastructure: it is not yet the render source (that swap is
# deferred to 6a/5g, where the gatherer's independent tree-walk retires).
sub monitor {
    my $self = shift;
    return $self->{'monitor'} //= Test2::Harness2::Runner::Monitor->new;
}

# Chunk 5e: Role::Service hands every transition frame here (one-way, no reply).
# Only the root runner process is the transition hub; a forked stage service does
# not fold transitions (it dispatches/reaps jobs and reports outcomes back to the
# root over runner.socket). Fold the already-decoded payload into the monitor.
sub service_transition {
    my $self = shift;
    my ($payload, $frame, $conn) = @_;

    return unless $self->{'rootpid'} == $$;

    $self->monitor->feed($payload);

    # Chunk 5f: forward every state-mutating transition to subscribed clients so
    # their snapshot-plus-transitions mirror stays whole (ARCH 4.2-4.3). The frame
    # is forwarded verbatim (no recompress) -- it is already a self-contained zstd
    # frame the subscriber's mirror folds the same way this monitor just did.
    #
    # Chunk 6.1: route per-run. Resolve the frame's run association (the
    # collector run_uuid, == the run's run_id) AFTER feeding the monitor, so a
    # later transition carrying only the uuid resolves against the tracked
    # collector. A run-less frame (the runner's own, a preload-stage lifecycle
    # transition) routes to every subscriber.
    $self->forward_frame($frame, $self->monitor->run_for_payload($payload))
        if $frame;

    return;
}

# Chunk 5f: a client subscribes to the runner's canonical state. We register the
# connection as a persistent subscriber (it stays open and receives forwarded
# mutation frames asynchronously) and reply with a serialized snapshot of the
# whole canonical state so the client's local mirror starts whole. Unlike the
# one-way submission requests this returns a reply (the snapshot). Only the root
# runner is the state hub; a forked stage service does not serve subscriptions.
#
# Chunk 6.1: per-run routing. The request may carry a run_id; the subscriber is
# then scoped to that run -- its snapshot is filtered to that run (plus the global
# bucket) and forward_frame thereafter sends it only that run's frames. A
# subscribe with no run_id is a global subscriber (the watch path): it gets the
# whole snapshot and every forwarded frame.
sub request_handler_subscribe {
    my $self = shift;
    my ($payload, $conn) = @_;

    return {ok => 0, error => 'not the runner state hub'}
        unless $self->{'rootpid'} == $$;

    my $run_id = $payload->{run_id};

    $self->add_subscriber($conn, $run_id) if defined $conn;

    return {ok => 1, snapshot => $self->monitor->snapshot($run_id)};
}

# Chunk 5f: the runner ORIGINATES some state mutations itself -- it dispatches a
# job to a stage, forks a job (running), and reaps a job (done). ARCH 4.2 is
# explicit these must reach subscribers too, not only the folded collector
# transitions, so the snapshot-plus-transitions contract stays whole. We express
# one as a harness_runner_job facet on the collector wire form, fold it into our
# own monitor (so a later snapshot includes it) and forward the same frame to
# subscribers (so their mirror folds it identically).
sub announce_job {
    my $self = shift;
    my ($job_id, $state, %extra) = @_;

    return unless $self->{'rootpid'} == $$;
    return unless defined $job_id;

    my $rj = {job_id => $job_id, state => $state, %extra};

    # Chunk 6.1: route this runner-originated mutation to its run's subscribers.
    # 'dispatched'/'running'/'retry'/'done' from the scheduler carry run_id in
    # %extra; a stage-reported 'done'/'retry' (from the stop_task/retry_task
    # request handlers) does not, so backfill it from the run_id the monitor
    # already tracked for the job at dispatch.
    if (!defined $rj->{run_id}) {
        my $known = $self->monitor->job($job_id);
        $rj->{run_id} = $known->{run_id} if $known && defined $known->{run_id};
    }

    my $payload = {facet_data => {harness_runner_job => $rj}};

    $self->monitor->feed($payload);

    my $frame = compress_blob(encode_json($payload));
    $self->forward_frame($frame, $rj->{run_id});

    return;
}

# Chunk 6.1-2: the runner originates a run-completion mutation. The persistent
# runner serves many runs and keeps its socket open, so a run-scoped subscriber
# (the `yath run` command) cannot key completion on the socket closing the way the
# transient `yath test` command does. Instead the runner announces each run's end
# over the socket -- folded into its own monitor (so a later snapshot carries it)
# and forwarded to that run's subscribers -- when the run leaves the active slot.
sub announce_run {
    my $self = shift;
    my ($run_id) = @_;

    return unless $self->{'rootpid'} == $$;
    return unless defined $run_id;
    return if $self->{'announced_runs'}->{$run_id}++;

    my $payload = {facet_data => {harness_run_end => {run_id => $run_id, stamp => time}}};

    $self->monitor->feed($payload);

    my $frame = compress_blob(encode_json($payload));
    $self->forward_frame($frame, $run_id);

    return;
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
