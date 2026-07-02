package Test2::Harness2::Renderer::Base;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use File::Spec();
use Time::HiRes qw/time sleep/;

use Test2::Harness2::Event;
use Test2::Harness2::JobReader;
use Test2::Harness2::RunnerReader;
use Test2::Harness2::Util qw/runner_events_file/;
use Test2::Harness2::Util::UUID qw/gen_uuid/;
use Test2::Harness2::Util::JSON qw/encode_json decode_json/;

use Test2::Harness2::Util::HashBase qw{
    <settings
    <run
    <run_id
    <workdir
    <show_runner_output
    <tail
    <tasks
    +service_readers

    +by_uuid
    +jobs
    +run_started

    <tests_seen
    <final_data
    +run_health

    dispatch_cb
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Renderer::Base - Reusable base that locates a collector's
recorded C<.jsonl.zst> events file from transition state and yields its recorded
events as a pure source.

=head1 DESCRIPTION

This is the C<§4.5> base renderer: it knows how to locate a collector's
C<events.jsonl.zst> file from the runner's transition state (a
L<Test2::Harness2::Runner::Monitor> mirror), open it B<by the absolute path the
transition carried> via L<Test2::Harness2::JobReader> /
L<Test2::Harness2::RunnerReader>, and hand every recorded event to its
C<dispatch_cb>. It is a B<pure event source>: the actual sink fan-out (the
C<render_event> renderers -- L<Test2::Harness2::Renderer::Formatter>, the jsonl
log L<App::Yath2::Renderer::Jsonl>, etc. -- plus the plugin
C<annotate_event> / C<handle_event> hooks and the assertion tally) is owned by
L<App::Yath2::RenderLoop>, which drives this base via the C<dispatch_cb> seam.
Consumers therefore see B<recorded> events rather than a live broadcast.

The base owns the reusable mechanics that any events-file consumer needs and that
were historically buried in the command-only orchestrator:

=over 4

=item *

The transition source -- a runner C<Monitor> mirror fed by a
L<Test2::Harness2::Runner::Subscriber> (or directly) -- and the per-collector
events-file location (collector uuid -> C<< monitor->collector($uuid)->{events_file} >>).

=item *

Reading one collector's recorded events file by path
(C<feed_events_file>) and the runner / stage output tail (C<step_runner_output>)
so other consumers (the C<watch> command, archived replay) can reuse it.

=item *

The run-level rollup (C<compute_final> / C<harness_final>) and the per-job
verdict bookkeeping.

=item *

The pure-source C<dispatch> seam (C<dispatch_cb>): every recorded event is handed
to the injected callback, which L<App::Yath2::RenderLoop> uses to collect the
events and then own the actual sink fan-out (renderers + plugins + the assertion
tally).

=back

It deliberately does B<not> pin any cross-event or per-job ordering policy; that
is a concrete renderer's job. The interim per-job 3-phase ordering lives in
L<Test2::Harness2::Renderer::Driver>, the command-side subclass, so a future
streaming / cross-job renderer can reuse this base without inheriting that
policy.

=head1 SYNOPSIS

    # Concrete subclasses implement step()/finalize() ordering policy on top of
    # the mechanics this base provides.
    package My::Renderer;
    use parent 'Test2::Harness2::Renderer::Base';

    sub step ($self, $monitor) {
        $self->render_run_start;
        $self->step_runner_output($monitor);
        for my $uuid ($monitor->new_completed) {
            my $c = $monitor->collector($uuid) or next;
            $self->feed_events_file($c->{events_file}, ...);
        }
    }

=cut

sub init ($self) {
    croak "settings is required"  unless $self->{+SETTINGS};

    $self->{+BY_UUID}            = {};
    $self->{+JOBS}               = {};
    $self->{+SERVICE_READERS}    = {};
    $self->{+TESTS_SEEN}   //= 0;
    $self->{+RUN_STARTED} = 0;

    # Seed the per-job-id rollup state from the task list the command already
    # holds (the same list the gatherer used to read from queue.jsonl). Every
    # queued job starts "unseen"; a job that produces a verdict is moved to seen.
    for my $task (@{$self->{+TASKS} // []}) {
        my $job_id = $task->{job_id} // next;
        $self->{+JOBS}{$job_id} = {
            job_id   => $job_id,
            file     => $task->{file},
            rel_file => $task->{rel_file},
            tries    => 0,
            verdict  => undef,
            launched => {},
        };
    }

    return;
}

=head1 PUBLIC METHODS

=over 4

=item $renderer->render_run_start

Emit the run-level C<harness_run> / C<harness_settings> event plus a
C<harness_job_queued> for every task (what the gatherer used to emit from its own
init / from C<queue.jsonl>), so the C<--show-run-info> path, the formatter's
progress counters, and the log have the run context. Idempotent.

=item $renderer->feed_events_file($events_file, %args)

Locate (open by absolute path) and feed every recorded event from one
collector's C<events.jsonl.zst> through C<dispatch> (the C<dispatch_cb> seam).
C<%args> map
onto the L<Test2::Harness2::JobReader> (C<job_id>, C<job_try>, C<file>). If
C<hold> is a coderef it is called with each decoded event B<before> dispatch and,
when it returns true, the event is withheld from dispatch and returned to the
caller instead (used by a subclass to hold a job's final C<harness_job_end> for
last-place rendering). Returns the list of held events.

When C<wait_terminal> is true the read B<bounded-waits> for the reader's terminal
record (the C<harness_process_exit> / C<harness_final_state> that marks the job
done) instead of stopping on the first temporarily-empty poll. A job's FINAL
verdict is settled from this terminal, so settling it off a transient EOF (the
events file not yet flushed with its terminal records, which happens because the
C<completed> transition the driver keys on arrives B<before> the separate, later
C<harness_final_state> record -- see L<Test2::Harness2::JobReader>) would
mis-render a passing job as FAILED. The wait is condition-driven with
C<Time::HiRes::sleep> backoff and a bounded cap (C<FEED_TERMINAL_TIMEOUT>), and
returns the moment the terminal arrives, so the healthy path (terminal already in
the file) does not wait at all. Every other caller (a runner/stage output tail)
leaves C<wait_terminal> false and gets the original poll-until-empty behavior.

=item $renderer->step_runner_output($monitor)

Tail the runner's own events file and each non-test service collector's events
file (located from the transition state), dispatching their (INTERNAL-shaped)
output lines, plus the flat-log + aux-log shims. Gated on
C<show_runner_output>.

=item $bool = $renderer->runner_output_done

True once the runner's own events file has been tailed (via C<step_runner_output>)
through its terminal C<harness_process_exit> record. The transient render loop
uses this to drain late runner output -- output the runner C<print>ed just before
closing its socket, which its collector parent may not have flushed into
C<runner-events.jsonl.zst> yet -- before finalizing. Returns false (not done)
until the runner-events reader has been created and seen its terminal record.

=item $count = $renderer->tests_seen

The number of test files launched so far. (The assertion tally now lives on the
render loop, which owns the fan-out; see L<App::Yath2::RenderLoop/asserts_seen>.)

=item $data = $renderer->final_data

The computed C<harness_final> rollup hash (pass / failed / retried / halted /
unseen). Undef until a subclass calls C<compute_final>.

=back

=cut

sub render_run_start ($self) {
    return if $self->{+RUN_STARTED};
    $self->{+RUN_STARTED} = 1;

    my $run = $self->{+RUN} or return;

    # Reduce the run + settings to plain data: the events flow through renderers
    # that dclone (Storable) the event, which dies on the CODE refs a live
    # Settings/Run object can hold. The gatherer used to get this for free by
    # JSON round-tripping the event over its pipe; do the same explicitly here.
    my $run_data      = decode_json(encode_json($run));
    my $settings_data = decode_json(encode_json($self->{+SETTINGS}));

    my $e = $self->event(
        0, undef, time,
        harness_run      => $run_data,
        harness_settings => $settings_data,
        about            => {no_display => 1},
    );

    $self->dispatch($e);

    # Emit a harness_job_queued for every task (what the gatherer used to emit
    # from queue.jsonl): the formatter's progress counters and job-name map key
    # on it.
    for my $task (@{$self->{+TASKS} // []}) {
        my $job_id = $task->{job_id} // next;
        my $qe     = $self->event(
            $job_id, $task->{is_try} // 0, $task->{stamp} // time,
            harness_job_queued => $task,
        );
        $self->dispatch($qe);
    }

    return;
}

# How long to bounded-wait, at most, for a job's events file to flush its terminal
# record (harness_process_exit / harness_final_state) when settling that job's
# FINAL verdict (wait_terminal). The driver keys a job's completion on the
# 'completed' transition, which the JobReader ordering comment notes arrives
# BEFORE the separate, later harness_final_state record + the file's terminal; if
# we settled the verdict on the transient EOF that gap produces, a passing job
# would render FAILED (empty final-state == fail=1 in synth_job_end). So wait for
# the real terminal. Bounded so a collector that died without ever writing its
# terminal (killed/aborted) cannot hang the command -- past the cap we fall back
# to the synthesized end. Mirrors DRAIN_RUNNER_OUTPUT_TIMEOUT in Command::test.
sub FEED_TERMINAL_TIMEOUT() { 5 }

# Read one collector's recorded events file BY PATH and feed every event through
# the renderers. This is the §4.5 events-file location mechanic, promoted
# out of the command-only Driver so watch + archived replay can reuse it. The
# optional `hold` coderef lets a subclass withhold specific events (e.g. the
# job's final harness_job_end) for its own ordering policy.
#
# With wait_terminal set the read bounded-waits for the reader's terminal record
# instead of stopping on the first empty poll, so a job's FINAL verdict is settled
# from the recorded terminal rather than a transient EOF (review P1: a passing job
# rendered FAILED because feed bailed before its harness_final_state had flushed).
# The healthy path (terminal already present) never sleeps. Other callers (output
# tails) leave wait_terminal false and keep the original poll-until-empty shape.
sub feed_events_file ($self, $events_file, %args) {
    return () unless defined $events_file && length $events_file;

    my $hold          = $args{hold};
    my $wait_terminal = $args{wait_terminal};

    my $reader = Test2::Harness2::JobReader->new(
        job_id      => $args{job_id},
        job_try     => $args{job_try} // 0,
        run_id      => $self->{+RUN_ID},
        file        => $args{file},
        events_file => $events_file,
    );

    my @held;
    my $start = time;
    my $delay = 0.001;
    until ($reader->done) {
        my @events = $reader->poll(1000);

        unless (@events) {
            # No new events this poll. Without wait_terminal keep the original
            # behavior (stop -- a tail picks up later). With wait_terminal we are
            # settling a final verdict, so bounded-wait for the terminal to flush
            # rather than settle off a transient EOF.
            last unless $wait_terminal;
            last if (time - $start) > FEED_TERMINAL_TIMEOUT;
            sleep $delay;
            $delay = $delay * 2 < 0.05 ? $delay * 2 : 0.05;
            next;
        }

        $delay = 0.001;
        for my $e (@events) {
            if ($hold && $hold->($e)) {
                push @held => $e;
                next;
            }
            $self->dispatch($e);
        }
    }

    return @held;
}

# Surface the runner's own output (runner-events.jsonl.zst) and each preload
# stage's output (the service collectors' events files) the same way the gatherer's
# process_runner_events did: tail each file with a RunnerReader and dispatch its
# remapped INTERNAL-shaped info lines. Tailing readers are kept per file across
# steps so appended frames are picked up live. Gated on show_runner_output (the
# --hide-runner-output display option).
#
# This is the runner/stage events-file location half of §4.5 -- the part `yath
# watch` reuses to render runner/global output. Both the transient and
# persistent runners (and their stages) are collector-wrapped, so EVERYTHING the
# runner and its stages print lands in an events file read here.
sub step_runner_output ($self, $monitor) {
    return unless $self->{+SHOW_RUNNER_OUTPUT};

    my $readers = $self->{+SERVICE_READERS};

    # The runner's own non-test collector does not report to the socket (it is the
    # hub), so add its events file explicitly by the known workdir path.
    if (my $dir = $self->{+WORKDIR}) {
        my $rfile = runner_events_file($dir);
        $readers->{$rfile} //= Test2::Harness2::RunnerReader->new(
            run_id      => $self->{+RUN_ID},
            events_file => $rfile,
            tail        => $self->{+TAIL},
        );
    }

    # Every other (non-test) service collector announces its events file over the
    # transition channel; pick those up as they appear. A plugin "aux" collector
    # is named "aux:NAME" -- render its output tagged with NAME (the conventional
    # "(NAME)" aux output), other services as plain INTERNAL.
    for my $uuid ($monitor->services) {
        my $c  = $monitor->collector($uuid) or next;
        my $ef = $c->{events_file}          or next;
        my $name = $c->{name} // 'service';

        my %extra;
        if (my ($aux) = $name =~ /^aux:(.+)$/) {
            %extra = (tag => uc($aux), label => "yath $aux");
        }
        else {
            %extra = (label => "yath $name");
        }

        $readers->{$ef} //= Test2::Harness2::RunnerReader->new(
            run_id      => $self->{+RUN_ID},
            events_file => $ef,
            tail        => $self->{+TAIL},
            %extra,
        );
    }

    for my $reader (values %$readers) {
        next if $reader->done;
        $self->dispatch($_) for $reader->poll(1000);
    }

    return;
}

# True once the runner's OWN events file (runner-events.jsonl.zst) has been read
# through to its terminal record (the runner collector's synthetic
# harness_process_exit, which RunnerReader recognizes as done). The runner closes
# its runner.socket -- the completion signal the transient render loop watches --
# the moment its service stops, which can be BEFORE its collector parent has
# flushed the runner's trailing stdout (e.g. a resource-cleanup print) into
# runner-events. Keying the drain on this predicate, rather than on the socket
# EOF alone, lets the command pull that late runner output into the log before
# finalizing.
#
# Returns true only once that runner-events reader exists AND has reached done; if
# the reader has not been created yet (the runner never produced an events file)
# it returns false so the caller falls back to its bounded timeout instead of
# spinning forever on a missing terminal.
sub runner_output_done ($self) {
    my $dir = $self->{+WORKDIR} or return 1;

    my $rfile  = runner_events_file($dir);
    my $reader = $self->{+SERVICE_READERS}{$rfile} or return 0;

    return $reader->done ? 1 : 0;
}

=head1 PRIVATE METHODS

=over 4

=item $job = $self->job_for($collector)

Resolve (and cache) the per-job-id rollup record for a collector, keyed by the
collector's rel_file name.

=item $self->dispatch($event)

Hand one harness event to the C<dispatch_cb> coderef. This is the pure-source
seam (#42): L<App::Yath2::RenderLoop::LiveProducer> installs a C<dispatch_cb>
that collects the ordered events into its queue, so the loop -- not this engine --
owns the actual sink fan-out (renderers + plugins + the assertion tally). The
callback is B<required>: dispatching before one is installed is a programming
error and croaks. (watch/test/stop all construct the engine, then the producer
installs the cb, before any event is dispatched.)

=item $data = $self->compute_final

Build the run-level C<harness_final> rollup from per-job verdicts and store it in
C<final_data>.

=item $self->note_verdict($job, $try, $end)

Record one try's pass/fail verdict (last-try-wins) into a job rollup record.

=item $event = $self->synth_job_end($job_id, $try, $file, $final_state)

Synthesize a C<harness_job_end> event from a collector's final state.

=item $e = $self->event($job_id, $job_try, $stamp, %facets)

Construct a wrapped L<Test2::Harness2::Event>.

=back

=cut

sub synth_job_end ($self, $job_id, $try, $file, $final_state) {
    my $fs = $final_state // {};
    my $skip;
    if (my $plan = $fs->{plan}) {
        $skip = $plan->{details} || "No reason given" unless $plan->{count};
    }

    my $task     = $self->task_for($job_id);
    my $job_name = $task ? $task->{job_name} : $job_id;

    return $self->event(
        $job_id, $try, time,
        harness_job     => {job_id => $job_id, job_name => $job_name, file => $file, is_try => $try},
        harness_job_end => {
            file     => $file,
            rel_file => defined($file) ? File::Spec->abs2rel($file) : undef,
            abs_file => defined($file) ? File::Spec->rel2abs($file) : undef,
            retry    => 0,
            fail     => $fs->{pass} ? 0 : 1,
            skip     => $skip,
            halt     => $fs->{halt},
            stamp    => $fs->{stamp} // time,
        },
    );
}

sub note_verdict ($self, $job, $try, $end) {
    return unless $job && $end;

    my $task         = $self->task_for($job->{job_id});
    my $retry_budget = ($task ? $task->{retry} : undef) // ($self->{+RUN} ? $self->{+RUN}->retry : 0) // 0;

    # Try ordinals are 1-based (R10 / #49): the first attempt is $try == 1 and the
    # job is allowed $retry_budget retries, so it will retry while $try <=
    # $retry_budget -- mirroring the runner's _collector_retry_if_tries decision. An
    # aborted end is terminal: the runner already made the no-retry decision, so it
    # always settles (a synthetic aborted render carries no real try ordinal).
    my $will_retry = $end->{fail} && !$end->{aborted} && (($try // 1) <= $retry_budget);
    $end->{retry} = 1 if $will_retry;

    # Last-try-wins verdict (overwritten each try); only settle on a try that is
    # not going to be retried.
    $job->{verdict} = {
        file => $end->{file},
        fail => $end->{fail} ? 1 : 0,
        halt => $end->{halt},
    } unless $will_retry;

    return;
}

sub task_for ($self, $job_id) {
    for my $task (@{$self->{+TASKS} // []}) {
        return $task if ($task->{job_id} // '') eq $job_id;
    }
    return undef;
}

sub job_for ($self, $c) {
    my $name = $c->{name} // return undef;

    for my $job (values %{$self->{+JOBS}}) {
        return $job if ($job->{rel_file} // '') eq $name;
        return $job if defined($job->{file}) && File::Spec->abs2rel($job->{file}) eq $name;
    }

    # A collector with no matching task (should not happen on the transient path)
    # gets a synthetic job record so it still rolls up.
    return $self->{+JOBS}{$name} //= {job_id => $name, file => $name, rel_file => $name, tries => 0, verdict => undef};
}

sub dispatch ($self, $e) {
    my $cb = $self->{+DISPATCH_CB}
        or croak "dispatch_cb is not set (the render loop owns the sink fan-out)";

    $cb->($e);
    return;
}

sub compute_final ($self) {
    my $final_data = {pass => 1};

    for my $job_id (keys %{$self->{+JOBS}}) {
        my $job     = $self->{+JOBS}{$job_id};
        my $verdict = $job->{verdict};

        unless ($verdict) {
            push @{$final_data->{unseen}} => [$job_id, $job->{rel_file} // $job->{file}];
            next;
        }

        my $file = defined($verdict->{file}) ? File::Spec->abs2rel($verdict->{file}) : ($job->{rel_file} // $job->{file});

        push @{$final_data->{failed}} => [$job_id, $file] if $verdict->{fail};

        my $tries = $job->{tries} // 1;
        push @{$final_data->{retried}} => [$job_id, $tries, $file, ($verdict->{fail} ? 'NO' : 'YES')]
            if $tries > 1;

        push @{$final_data->{halted}} => [$job_id, $file, $verdict->{halt}]
            if defined($verdict->{halt}) && length($verdict->{halt});
    }

    $final_data->{pass} = 0 if $final_data->{failed} or $final_data->{unseen};

    # Post-pass collector failure (A3, ARCHITECTURE.md §5.4): the runner flagged a
    # suite-level health failure (a collector that malfunctioned AFTER reporting a
    # pass). The tests themselves stay green -- nothing is added to {failed} -- but
    # the suite fails so the command exits non-zero. Record the reasons so the
    # summary can surface them.
    if (my $health = $self->{+RUN_HEALTH}) {
        if (@$health) {
            $final_data->{pass}          = 0;
            $final_data->{health_errors} = [map { $_->{reason} } @$health];
        }
    }

    $self->{+FINAL_DATA} = $final_data;
    return $final_data;
}

sub event ($self, $job_id, $job_try, $stamp, %facets) {
    return Test2::Harness2::Event->new(
        stamp      => $stamp,
        job_id     => $job_id,
        job_try    => $job_try,
        event_id   => gen_uuid(),
        run_id     => $self->{+RUN_ID},
        facet_data => \%facets,
    );
}

1;

__END__

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

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

See F<http://dev.perl.org/licenses/>

=cut
