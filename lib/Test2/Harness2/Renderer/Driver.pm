package Test2::Harness2::Renderer::Driver;
use v5.38;

use parent 'Test2::Harness2::Renderer::Base';

our $VERSION = '2.000000';

use File::Spec();
use Time::HiRes qw/time/;

use Test2::Harness2::JobReader;

use Test2::Harness2::Util::HashBase qw{
    +aborted_rendered
    <live
    +tail_readers
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Renderer::Driver - Command-side renderer that pins the per-job
ordering contract on top of L<Test2::Harness2::Renderer::Base>.

=head1 DESCRIPTION

This is the command-side render path. The reusable mechanics -- locating a
collector's C<events.jsonl.zst> from transition state, reading it by path, the
runner/stage output tail, and the run-level rollup -- live in the base class
L<Test2::Harness2::Renderer::Base>. The sink fan-out (the C<render_event>
renderers + plugins) lives in L<App::Yath2::RenderLoop>, which drives this engine
as a pure event source via the C<dispatch_cb> seam. This subclass adds B<only>
the per-job ordering policy on top of that base, so the base stays free of any
ordering policy for other consumers (C<watch>, archived replay).

Instead of consuming a spawned gatherer's reconstructed event stream, the
C<test> / C<run> command subscribes to the runner's canonical state
(L<Test2::Harness2::Runner::Subscriber>) and hands this driver the resulting
mirror (a L<Test2::Harness2::Runner::Monitor>) on each loop.

=head2 ORDERING CONTRACT

The guarantee is B<per-job chronological order only>: a single job's own events
always render in the order that job produced them. Events from B<different> jobs
may interleave. Cross-job chronological ordering is explicitly B<not> a
guarantee. This driver implements that contract two ways, selected by the
C<live> attribute:

=over 4

=item Default (C<live> off) -- transitions live, events at end.

Each test collector's lifecycle (queued / launch / start) renders in realtime as
the collector appears. When that collector completes (its C<harness_final_state>
transition has arrived) its whole C<events.jsonl.zst> file is fetched B<by the
absolute path the transition carried> and fed through the renderers and logger,
then the job's final completion (C<harness_job_end>) renders last. A job's body
therefore renders as one contiguous block just before its end, never
interleaved with another job's body. Driven by C<step> / C<finalize>.

=item Live tail (C<live> on) -- every job tailed as it appears.

Each test collector's lifecycle renders as it appears (as above), then this
driver opens a tailing reader on its events file and streams that job's events
B<as they are written>. On each tick every open reader is drained, so under
concurrency one job's lines interleave with another's in arrival order -- the
1.0 tail-the-files shape. Per-job order is still preserved (each reader yields
its own job's events in file order); only the cross-job interleave changes.
Every emitted event carries its job/process/collector identity, so a renderer
attributes each line to its job (the default terminal renderer prefixes each
line with the job's index). Driven by C<tail> / C<finalize>.

=back

Both modes share the same launch lifecycle, abort handling, and run-level
rollup; only the per-job body delivery differs.

The run-level rollup (C<harness_final> / pass / retried / failed / halted /
unseen) and the pass/fail decision are computed here, command-side, from the
subscription state plus the events files -- never from a gatherer event.

=head1 SYNOPSIS

    my $driver = Test2::Harness2::Renderer::Driver->new(
        settings  => $settings,
        run       => $run,
        run_id    => $run_id,
        tasks     => \@tasks,
    );

    # The loop installs a dispatch_cb; the engine is then a pure source.
    my $producer = App::Yath2::RenderLoop::LiveProducer->new(engine => $driver, ...);

    $driver->render_run_start;
    while (...) {
        $subscriber->poll;
        $driver->step($subscriber->monitor);
    }
    $driver->finalize($subscriber->monitor);
    my $final_data = $driver->final_data;

=cut

sub init ($self) {
    $self->SUPER::init();
    $self->{+ABORTED_RENDERED} = {};
    $self->{+TAIL_READERS}     = {};
    $self->{+LIVE} //= 0;
    return;
}

=head1 PUBLIC METHODS

This class inherits the reusable mechanics from
L<Test2::Harness2::Renderer::Base> (C<render_run_start>, C<final_data>,
C<tests_seen>, C<asserts_seen>, ...) and adds the per-job ordering policy:

=over 4

=item $driver->step($monitor)

Default-mode tick: drain the subscription mirror's change-lists and render any
newly-appeared or newly-completed jobs (transitions live, a job's whole events
file fed at completion).

=item $driver->tail($monitor)

Live-mode tick: render newly-appeared jobs' launch lifecycle, then drain every
open job's events-file tailing reader so each job streams as it is written
(interleaved across jobs, in order within a job). The C<live> attribute selects
this over C<step>.

=item $driver->finalize($monitor)

Final drain pass (mode-appropriate), then compute the run-level C<harness_final>
rollup and the pass/fail decision into C<final_data>.

=back

=cut

sub step ($self, $monitor) {
    $self->render_run_start;

    $self->step_runner_output($monitor);

    # Phase 1: a freshly-seen test collector -> render its launch lifecycle.
    for my $uuid ($monitor->new_collectors) {
        my $c = $monitor->collector($uuid) or next;
        next unless ($c->{category} // '') eq 'test';
        $self->_render_launch($uuid, $c);
    }

    # Drain the other realtime change-lists so the mirror does not retain them;
    # failing/diagnosing are realtime signals folded into per-event rendering at
    # completion, so we do not double-render them here.
    $monitor->new_failing;
    $monitor->new_diagnosing;

    # Phases 2 + 3: a completed test collector whose final-state has arrived ->
    # feed its events file, then render its final completion.
    for my $uuid ($monitor->new_completed) {
        my $c = $monitor->collector($uuid) or next;
        next unless ($c->{category} // '') eq 'test';
        $self->_render_completion($uuid, $c);
    }

    # A job the runner watchdog aborted (its collector will never report
    # completion) -- render a synthetic failed completion. The runner is the
    # completion authority on the transient path; the driver renders + rolls up
    # its verdict.
    for my $job_id ($monitor->new_aborted_jobs) {
        $self->_render_aborted($monitor->job($job_id));
    }

    $monitor->new_finalized;
    $monitor->new_test_exits;

    return;
}

sub tail ($self, $monitor) {
    $self->render_run_start;

    $self->step_runner_output($monitor);

    # A freshly-seen test collector -> render its launch lifecycle (same as the
    # default mode), then start tailing its events file below.
    for my $uuid ($monitor->new_collectors) {
        my $c = $monitor->collector($uuid) or next;
        next unless ($c->{category} // '') eq 'test';
        $self->_render_launch($uuid, $c);
    }

    # failing/diagnosing are realtime signals folded into the tailed per-event
    # stream, so just drain them off the mirror without double-rendering.
    $monitor->new_failing;
    $monitor->new_diagnosing;

    # Tail every test collector whose events file has appeared, streaming each
    # job's events as they are written. Readers across jobs interleave; each
    # reader keeps its own job in file order.
    $self->_tail_test_collectors($monitor);

    # The 'completed' transition lets a tailed reader settle without a bounded
    # wait: drain it once it is flagged so the late records flush before the run
    # ends. Aborted jobs (no events file) still need the synthetic completion.
    $monitor->new_completed;

    for my $job_id ($monitor->new_aborted_jobs) {
        $self->_render_aborted($monitor->job($job_id));
    }

    $monitor->new_finalized;
    $monitor->new_test_exits;

    return;
}

sub finalize ($self, $monitor) {
    return $self->_finalize_live($monitor) if $self->{+LIVE};

    $self->step($monitor);

    # Any completed-but-not-yet-rendered test collector is caught by a final sweep
    # over every known test collector. This covers two finalize races:
    #
    #   1. Its 'completed' transition was drained off new_completed on the last
    #      loop poll without us rendering it.
    #
    #   2. The persistent `run` path leaves this loop on run_done (the scheduler
    #      cleared the run) WITHOUT proving every per-job harness_final_state +
    #      events-file terminal was forwarded/read, so a late job can still be
    #      sitting 'complete' with no folded final_state.
    #
    # Key the sweep on the collector having reached a terminal STATUS (complete /
    # finalized), not on final_state being folded -- the final_state transition
    # may lag, and _render_completion's bounded wait_terminal read settles the
    # verdict from the events-file terminal regardless. Rendering off final_state
    # alone here would drop a still-unfolded late job (review P1 persistent
    # compounding).
    for my $uuid ($monitor->tests) {
        my $c = $monitor->collector($uuid) or next;
        next if $self->{+BY_UUID}{$uuid}{ended};

        my $status = $c->{status} // '';
        next unless $c->{final_state} || $status eq 'complete' || $status eq 'finalized';

        $self->_render_completion($uuid, $c);
    }

    $self->_emit_run_rollup($monitor);

    return;
}

=head1 PRIVATE METHODS

=over 4

=item $self->_render_launch($uuid, $collector)

Phase 1: synthesize and dispatch the C<harness_job_queued> /
C<harness_job_launch> / C<harness_job_start> lifecycle for a newly-seen test
collector.

=item $self->_render_aborted($runner_job)

Render a job the runner watchdog aborted: synthesize its launch (if never seen),
an aborted C<harness_job_exit>, and a failed C<harness_job_end>, then roll up the
failure -- the gatherer's C<_abort_stalled_jobs> shape, command-side.

=item $self->_render_completion($uuid, $collector)

Default mode: read the collector's events file by path (via the base's
C<feed_events_file>, holding the final C<harness_job_end>), then dispatch the
synthesized final C<harness_job_end>.

=item $self->_tail_test_collectors($monitor)

Live mode: for every test collector with an events file, keep a tailing
L<Test2::Harness2::JobReader> and dispatch any new records it has, settling the
job's verdict when its terminal C<harness_job_end> is read. Each reader yields
its own job's events in file order; draining them all per tick interleaves the
jobs.

=item @events = $self->_tail_reader($uuid, $collector)

Open (once) and poll one collector's tailing reader, dispatching its new events
and noting the verdict when the job's C<harness_job_end> arrives.

=item $self->_finalize_live($monitor)

Live-mode finalize: one last tail pass that bounded-waits each still-open reader
for its terminal, then the shared run rollup.

=item $self->_emit_run_rollup($monitor)

Shared by both modes: one last runner-output slurp, fold the suite-level health
failures, C<compute_final>, and dispatch the run-level C<harness_final> event.

=back

=cut

sub _render_launch ($self, $uuid, $c) {
    my $job   = $self->job_for($c);
    my $entry = $self->{+BY_UUID}{$uuid} //= {ended => 0};

    return if $entry->{launched}++;

    my $job_id = $job ? $job->{job_id} : $uuid;
    my $file   = $job ? $job->{file}   : $c->{name};
    my $try    = $c->{try} // 0;
    my $stamp  = time;

    $job->{tries}++ if $job;
    $self->{+TESTS_SEEN}++;

    my $task     = $self->task_for($job_id);
    my $job_name = $task ? $task->{job_name} : $job_id;

    my $e = $self->event(
        $job_id, $try, $stamp,
        harness_job       => {job_id => $job_id, job_name => $job_name, file => $file, is_try => $try},
        harness_job_start => {
            details  => "Job $job_id started",
            job_id   => $job_id,
            stamp    => $stamp,
            file     => $file,
            rel_file => defined($file) ? File::Spec->abs2rel($file) : undef,
            abs_file => defined($file) ? File::Spec->rel2abs($file) : undef,
        },
        harness_job_launch => {stamp => $stamp, retry => $try},
    );

    $self->dispatch($e);
    return;
}

# Render a job the runner watchdog aborted. There is no collector
# events file to walk (the collector never finalized, or never started), so we
# synthesize the launch (if it was never rendered) plus an aborted
# harness_job_exit and a failed harness_job_end, and roll up the failure
# command-side.
sub _render_aborted ($self, $rj) {
    return unless $rj;
    my $job_id = $rj->{job_id} // return;

    my $job = $self->{+JOBS}{$job_id};
    return if $job && $job->{verdict};    # already settled normally

    my $file   = $rj->{file} // ($job ? $job->{file} : undef);
    my $try    = 0;
    my $reason = $rj->{details} // "Runner aborted this job before it completed";

    # If the launch was never rendered (the collector never started), render it
    # now so the aborted job has a header line.
    my $entry = $self->{+ABORTED_RENDERED} //= {};
    return if $entry->{$job_id}++;

    my $task     = $self->task_for($job_id);
    my $job_name = $task ? $task->{job_name} : $job_id;
    $self->{+TESTS_SEEN}++;
    $job->{tries}++ if $job;

    my $stamp = time;

    my $launch = $self->event(
        $job_id, $try, $stamp,
        harness_job       => {job_id => $job_id, job_name => $job_name, file => $file, is_try => $try},
        harness_job_start => {
            details  => "Job $job_id started",
            job_id   => $job_id,
            stamp    => $stamp,
            file     => $file,
            rel_file => defined($file) ? File::Spec->abs2rel($file) : undef,
            abs_file => defined($file) ? File::Spec->rel2abs($file) : undef,
        },
        harness_job_launch => {stamp => $stamp, retry => $try},
    );
    $self->dispatch($launch);

    my $end_facet = {
        file     => $file,
        rel_file => defined($file) ? File::Spec->abs2rel($file) : undef,
        abs_file => defined($file) ? File::Spec->rel2abs($file) : undef,
        retry    => 0,
        fail     => 1,
        aborted  => 1,
        stamp    => $stamp,
    };

    my $e = $self->event(
        $job_id, $try, $stamp,
        harness_job      => {job_id => $job_id, job_name => $job_name, file => $file, is_try => $try},
        harness_job_exit => {
            details => $reason,
            exit    => -1,
            code    => -1,
            signal  => 0,
            dumped  => 0,
            retry   => 0,
            aborted => 1,
            job_id  => $job_id,
            job_try => $try,
            stamp   => $stamp,
        },
        harness_job_end => $end_facet,
        info            => [{details => $reason, tag => "INTERNAL", debug => 1, important => 1}],
    );

    $self->note_verdict($job, $try, $end_facet);
    $self->dispatch($e);

    return;
}

sub _render_completion ($self, $uuid, $c) {
    my $entry = $self->{+BY_UUID}{$uuid} //= {ended => 0};
    return if $entry->{ended};
    $entry->{ended} = 1;

    # The launch may have been missed if the collector appeared and completed
    # between two polls; render it now so its body has context.
    $self->_render_launch($uuid, $c) unless $entry->{launched};

    my $job    = $self->job_for($c);
    my $job_id = $job ? $job->{job_id} : $uuid;
    my $file   = $job ? $job->{file}   : $c->{name};
    my $try    = $c->{try} // 0;

    # Phase 2: read the whole events file BY PATH and feed every event, holding
    # the synthesized harness_job_end so it renders LAST (phase 3).
    #
    # The 'completed' transition that put this uuid on new_completed arrives
    # BEFORE the separate, later harness_final_state record + the events file's
    # terminal (see Test2::Harness2::JobReader). So bounded-wait for the file's
    # terminal (wait_terminal) before settling the verdict: settling off the
    # transient EOF here -- with $c->{final_state} also not yet folded -- would
    # synth an empty-final-state harness_job_end, which synth_job_end treats as
    # fail=1, and once $entry->{ended} is set the real final-state can never
    # correct it. The healthy path (terminal already flushed) does not wait.
    my ($job_end) = $self->feed_events_file(
        $c->{events_file},
        job_id        => $job_id,
        job_try       => $try,
        file          => $file,
        wait_terminal => 1,
        hold          => sub ($e) { $e->{facet_data}{harness_job_end} ? 1 : 0 },
    );

    $job_end //= $self->synth_job_end($job_id, $try, $file, $c->{final_state});

    $self->note_verdict($job, $try, $job_end->{facet_data}{harness_job_end});

    # Phase 3: the job's final completion renders last.
    $self->dispatch($job_end);
    return;
}

# How long to bounded-wait, at most, at finalize for a still-open tailing reader
# to flush its terminal record. The live tail streams a job as it is written, so
# the reader is usually already done by finalize; this only covers a job whose
# 'completed' transition raced ahead of its events-file terminal flush (the same
# gap Test2::Harness2::Renderer::Base::FEED_TERMINAL_TIMEOUT covers in default
# mode). Bounded so a collector that died without writing its terminal cannot
# hang the command -- past the cap we synthesize the end from final_state.
sub TAIL_TERMINAL_TIMEOUT() { 5 }

sub _tail_test_collectors ($self, $monitor) {
    for my $uuid ($monitor->tests) {
        my $c = $monitor->collector($uuid) or next;
        next if $self->{+BY_UUID}{$uuid}{ended};
        $self->_tail_reader($uuid, $c);
    }

    return;
}

sub _tail_reader ($self, $uuid, $c) {
    my $entry = $self->{+BY_UUID}{$uuid} //= {ended => 0};
    return if $entry->{ended};

    my $events_file = $c->{events_file};
    return unless defined $events_file && length $events_file;

    # The launch may have been missed if the collector appeared and was tailed in
    # the same tick it first showed up; render it now so its body has context.
    $self->_render_launch($uuid, $c) unless $entry->{launched};

    my $job    = $self->job_for($c);
    my $job_id = $job ? $job->{job_id} : $uuid;
    my $file   = $job ? $job->{file}   : $c->{name};
    my $try    = $c->{try} // 0;

    my $reader = $self->{+TAIL_READERS}{$uuid} //= Test2::Harness2::JobReader->new(
        job_id      => $job_id,
        job_try     => $try,
        run_id      => $self->{+RUN_ID},
        file        => $file,
        events_file => $events_file,
    );

    # Drain whatever the file has grown by since the last tick. The reader yields
    # this job's events in file order, and synthesizes the terminal
    # harness_job_end off the recorded harness_final_state -- a real terminal, so
    # the tail never settles a premature (false-FAIL) verdict.
    for my $e ($reader->poll(1000)) {
        if (my $end = $e->{facet_data}{harness_job_end}) {
            $self->note_verdict($job, $try, $end);
            $entry->{ended} = 1;
        }
        $self->dispatch($e);
    }

    return;
}

sub _finalize_live ($self, $monitor) {
    $self->tail($monitor);

    # Bounded-wait each still-open reader for its terminal so a job whose
    # 'completed' raced its events-file flush settles its TRUE verdict, then fall
    # back to a synthesized end for any job with no readable terminal (collector
    # died / events file never appeared) so the rollup is complete.
    for my $uuid ($monitor->tests) {
        my $c     = $monitor->collector($uuid) or next;
        my $entry = $self->{+BY_UUID}{$uuid} //= {ended => 0};
        next if $entry->{ended};

        my $start = time;
        until ($entry->{ended}) {
            $self->_tail_reader($uuid, $c);
            last if $entry->{ended};
            last if (time - $start) > TAIL_TERMINAL_TIMEOUT;
            $self->step_runner_output($monitor);
            Time::HiRes::sleep(0.02);
        }

        next if $entry->{ended};

        my $status = $c->{status} // '';
        next unless $c->{final_state} || $status eq 'complete' || $status eq 'finalized';

        $self->_render_launch($uuid, $c) unless $entry->{launched};

        my $job    = $self->job_for($c);
        my $job_id = $job ? $job->{job_id} : $uuid;
        my $file   = $job ? $job->{file}   : $c->{name};
        my $try    = $c->{try} // 0;

        my $job_end = $self->synth_job_end($job_id, $try, $file, $c->{final_state});
        $self->note_verdict($job, $try, $job_end->{facet_data}{harness_job_end});
        $entry->{ended} = 1;
        $self->dispatch($job_end);
    }

    $self->_emit_run_rollup($monitor);

    return;
}

sub _emit_run_rollup ($self, $monitor) {
    # One last slurp of runner/stage output before the final rollup.
    $self->step_runner_output($monitor);

    # Carry the runner's suite-level health failures (a post-pass collector
    # failure, ARCHITECTURE.md §5.4) into the rollup so compute_final can mark the
    # suite failed even though every test passed.
    $self->{+RUN_HEALTH} = $monitor->run_health if $monitor->can('run_health');

    my $final_data = $self->compute_final;

    # Emit the run-level harness_final event into the render/log stream, exactly
    # as the gatherer used to (the log's penultimate record is this event, the
    # last is the null terminator the command writes on stop). The pass/fail
    # exit decision the command makes reads final_data directly.
    my $fe = $self->event(0, undef, time, harness_final => $final_data);
    $self->dispatch($fe);

    return;
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
