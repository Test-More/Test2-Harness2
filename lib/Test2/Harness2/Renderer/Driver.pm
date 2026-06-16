package Test2::Harness2::Renderer::Driver;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use File::Spec();
use Time::HiRes qw/time/;

use Test2::Harness2::Event;
use Test2::Harness2::Collector::JobReader;
use Test2::Harness2::Collector::RunnerReader;
use Test2::Harness2::Util::File::Stream;
use Test2::Harness2::Util qw/runner_events_file/;
use Test2::Harness2::Util::UUID qw/gen_uuid/;
use Test2::Harness2::Util::JSON qw/encode_json decode_json/;

use Test2::Harness2::Util::HashBase qw{
    <settings
    <renderers
    +logger
    <run
    <run_id
    <workdir
    <show_runner_output
    <tasks
    +service_readers

    +annotate_plugins
    +handle_plugins

    +by_uuid
    +jobs
    +run_started
    +aux_handles

    <tests_seen
    <asserts_seen
    <final_data
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Renderer::Driver - Command-side renderer driver that turns a
runner subscription into rendered output.

=head1 DESCRIPTION

This is the interim (chunk 6a) command-side render path. Instead of consuming a
spawned gatherer's reconstructed event stream, the C<test> / C<run> command
subscribes to the runner's canonical state
(L<Test2::Harness2::Runner::Subscriber>) and hands this driver the resulting
mirror (a L<Test2::Harness2::Runner::Monitor>) on each loop. The driver folds
the subscription into rendered output with a B<per-job> ordering contract:

=over 4

=item 1.

When a test collector first appears, its lifecycle (queued / launch / start) is
rendered in realtime.

=item 2.

When that collector completes (its C<harness_final_state> transition has
arrived), its C<events.jsonl.zst> file is fetched B<by the absolute path the
transition carried> and B<all> of its events are fed through the renderers and
logger (preserving the plugin C<annotate_event> hook).

=item 3.

The job's final completion (C<harness_job_end>) renders B<last>.

=back

Cross-job chronological ordering is explicitly not attempted; this is the
interim shape described in the architecture migration note, superseded later by
the base-renderer rewrite.

The run-level rollup (C<harness_final> / pass / retried / failed / halted /
unseen) and the pass/fail decision are computed here, command-side, from the
subscription state plus the events files -- never from a gatherer event.

=head1 SYNOPSIS

    my $driver = Test2::Harness2::Renderer::Driver->new(
        settings  => $settings,
        renderers => $renderers,
        logger    => $logger,
        run       => $run,
        run_id    => $run_id,
        tasks     => \@tasks,
        plugins   => $plugins,
    );

    $driver->render_run_start;
    while (...) {
        $subscriber->poll;
        $driver->step($subscriber->monitor);
    }
    $driver->finalize($subscriber->monitor);
    my $final_data = $driver->final_data;

=cut

sub init ($self) {
    croak "settings is required"  unless $self->{+SETTINGS};
    croak "renderers is required" unless $self->{+RENDERERS};

    my $plugins = delete($self->{plugins}) // [];
    $self->{+ANNOTATE_PLUGINS} = [grep { $_->can('annotate_event') } @$plugins];
    $self->{+HANDLE_PLUGINS}   = [grep { $_->can('handle_event') } @$plugins];

    $self->{+BY_UUID}         = {};
    $self->{+JOBS}            = {};
    $self->{+SERVICE_READERS} = {};
    $self->{+AUX_HANDLES}     = {};
    $self->{+TESTS_SEEN}   //= 0;
    $self->{+ASSERTS_SEEN} //= 0;
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

=item $driver->render_run_start

Emit the run-level C<harness_run> / C<harness_settings> event (what the gatherer
used to emit from its own init), so the C<--show-run-info> path and the log have
the run context. Idempotent.

=item $driver->step($monitor)

Drain the subscription mirror's change-lists and render any newly-appeared or
newly-completed jobs (the per-job 3-phase seam above).

=item $driver->finalize($monitor)

Final drain pass, then compute the run-level C<harness_final> rollup and the
pass/fail decision into C<final_data>.

=item $count = $driver->tests_seen

=item $count = $driver->asserts_seen

The number of test files launched and assertions seen so far.

=item $data = $driver->final_data

The computed C<harness_final> rollup hash (pass / failed / retried / halted /
unseen). Undef until C<finalize>.

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

    my $e = $self->_event(
        0, undef, time,
        harness_run      => $run_data,
        harness_settings => $settings_data,
        about            => {no_display => 1},
    );

    $self->_dispatch($e);

    # Emit a harness_job_queued for every task (what the gatherer used to emit
    # from queue.jsonl): the formatter's progress counters and job-name map key
    # on it.
    for my $task (@{$self->{+TASKS} // []}) {
        my $job_id = $task->{job_id} // next;
        my $qe     = $self->_event(
            $job_id, $task->{is_try} // 0, $task->{stamp} // time,
            harness_job_queued => $task,
        );
        $self->_dispatch($qe);
    }

    return;
}

sub step ($self, $monitor) {
    $self->render_run_start;

    $self->_step_runner_output($monitor);

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

    $monitor->new_finalized;
    $monitor->new_test_exits;

    return;
}

sub finalize ($self, $monitor) {
    $self->step($monitor);

    # Any collector that completed but whose 'completed' transition was already
    # drained without us having rendered it (race on the last poll) is caught by
    # a final sweep over every known test collector.
    for my $uuid ($monitor->tests) {
        my $c = $monitor->collector($uuid) or next;
        next unless $c->{final_state};
        next if $self->{+BY_UUID}{$uuid}{ended};
        $self->_render_completion($uuid, $c);
    }

    # One last slurp of runner/stage output before the final rollup.
    $self->_step_runner_output($monitor);

    $self->{+FINAL_DATA} = $self->_compute_final;

    # Emit the run-level harness_final event into the render/log stream, exactly
    # as the gatherer used to (the log's penultimate record is this event, the
    # last is the null terminator the command writes on stop). The pass/fail
    # exit decision the command makes reads final_data directly.
    my $fe = $self->_event(0, undef, time, harness_final => $self->{+FINAL_DATA});
    $self->_dispatch($fe);

    return;
}

=head1 PRIVATE METHODS

=over 4

=item $self->_render_launch($uuid, $collector)

Phase 1: synthesize and dispatch the C<harness_job_queued> /
C<harness_job_launch> / C<harness_job_start> lifecycle for a newly-seen test
collector.

=item $self->_render_completion($uuid, $collector)

Phases 2 + 3: read the collector's events file by path, dispatch every event,
then dispatch the synthesized final C<harness_job_end>.

=item $self->_step_runner_output($monitor)

Tail the runner's own events file and each non-test service collector's events
file, dispatching their (INTERNAL-shaped) output lines. Gated on
C<show_runner_output>.

=item $self->_step_aux_logs

Tail C<< $workdir/aux_logs/*.log >> -- plugin shellcall output that bypasses the
runner collector -- and dispatch each line as INTERNAL-shaped info.

=item $job = $self->_job_for($collector)

Resolve (and cache) the per-job-id rollup record for a collector, keyed by the
collector's rel_file name.

=item $self->_dispatch($event)

Run one harness event through annotate plugins, the logger, the renderers, and
the handle plugins (the same path the gatherer-fed render loop used).

=item $data = $self->_compute_final

Build the run-level C<harness_final> rollup from per-job verdicts.

=item $e = $self->_event($job_id, $job_try, $stamp, %facets)

Construct a wrapped L<Test2::Harness2::Event>.

=back

=cut

sub _render_launch ($self, $uuid, $c) {
    my $job   = $self->_job_for($c);
    my $entry = $self->{+BY_UUID}{$uuid} //= {ended => 0};

    return if $entry->{launched}++;

    my $job_id = $job ? $job->{job_id} : $uuid;
    my $file   = $job ? $job->{file}   : $c->{name};
    my $try    = $c->{try} // 0;
    my $stamp  = time;

    $job->{tries}++ if $job;
    $self->{+TESTS_SEEN}++;

    my $task     = $self->_task_for($job_id);
    my $job_name = $task ? $task->{job_name} : $job_id;

    my $e = $self->_event(
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

    $self->_dispatch($e);
    return;
}

sub _render_completion ($self, $uuid, $c) {
    my $entry = $self->{+BY_UUID}{$uuid} //= {ended => 0};
    return if $entry->{ended};
    $entry->{ended} = 1;

    # The launch may have been missed if the collector appeared and completed
    # between two polls; render it now so its body has context.
    $self->_render_launch($uuid, $c) unless $entry->{launched};

    my $job    = $self->_job_for($c);
    my $job_id = $job ? $job->{job_id} : $uuid;
    my $file   = $job ? $job->{file}   : $c->{name};
    my $try    = $c->{try} // 0;

    my $events_file = $c->{events_file};
    my $job_end;

    if (defined $events_file && length $events_file) {
        # Phase 2: read the whole events file BY PATH and feed every event.
        my $reader = Test2::Harness2::Collector::JobReader->new(
            job_id      => $job_id,
            job_try     => $try,
            run_id      => $self->{+RUN_ID},
            file        => $file,
            events_file => $events_file,
        );

        until ($reader->done) {
            my @events = $reader->poll(1000);
            last unless @events;
            for my $e (@events) {
                # Phase 3: hold the synthesized harness_job_end so it renders LAST,
                # after the rest of the job's body.
                if ($e->{facet_data}{harness_job_end}) {
                    $job_end = $e;
                    next;
                }
                $self->_dispatch($e);
            }
        }
    }

    $job_end //= $self->_synth_job_end($job_id, $try, $file, $c->{final_state});

    $self->_note_verdict($job, $try, $job_end->{facet_data}{harness_job_end});

    # Phase 3: the job's final completion renders last.
    $self->_dispatch($job_end);
    return;
}

# Surface the runner's own output (runner-events.jsonl.zst) and each transient
# preload stage's output (the service collectors' events files) the same way the
# gatherer's process_runner_events did: tail each file with a RunnerReader and
# dispatch its remapped INTERNAL-shaped info lines. Tailing readers are kept per
# file across steps so appended frames are picked up live. Gated on
# show_runner_output (the --hide-runner-output display option).
sub _step_runner_output ($self, $monitor) {
    return unless $self->{+SHOW_RUNNER_OUTPUT};

    my $readers = $self->{+SERVICE_READERS};

    # The runner's own non-test collector does not report to the socket (it is the
    # hub), so add its events file explicitly by the known workdir path.
    if (my $dir = $self->{+WORKDIR}) {
        my $rfile = runner_events_file($dir);
        $readers->{$rfile} //= Test2::Harness2::Collector::RunnerReader->new(
            run_id      => $self->{+RUN_ID},
            events_file => $rfile,
        );
    }

    # Every other (non-test) service collector announces its events file over the
    # transition channel; pick those up as they appear.
    for my $uuid ($monitor->services) {
        my $c  = $monitor->collector($uuid) or next;
        my $ef = $c->{events_file}          or next;
        $readers->{$ef} //= Test2::Harness2::Collector::RunnerReader->new(
            run_id      => $self->{+RUN_ID},
            events_file => $ef,
            label       => "yath " . ($c->{name} // 'service'),
        );
    }

    for my $reader (values %$readers) {
        next if $reader->done;
        $self->_dispatch($_) for $reader->poll(1000);
    }

    $self->_step_aux_logs;

    return;
}

# Tail $workdir/aux_logs/*.log -- output from plugin shellcall subprocesses that
# deliberately redirect away from the runner collector's captured streams (so it
# never reaches runner-events.jsonl.zst). Surface each line as INTERNAL-shaped
# info, exactly as the gatherer's process_aux_logs did.
sub _step_aux_logs ($self) {
    my $dir    = $self->{+WORKDIR} or return;
    my $auxdir = File::Spec->catdir($dir, 'aux_logs');
    return unless -d $auxdir;

    my $handles = $self->{+AUX_HANDLES};

    opendir(my $dh, $auxdir) or return;
    for my $path (readdir($dh)) {
        next if $path =~ m/^\.+$/;
        next if $handles->{$path};

        my $tag = uc($path);
        next unless $tag =~ s/\.LOG$//;

        my $debug = 0;
        if ($tag =~ s/\W*(STDERR|STDOUT)\W*//g) {
            $debug = 1 if $1 && uc($1) eq 'STDERR';
        }

        $handles->{$path} = {
            tag    => $tag,
            debug  => $debug,
            stream => Test2::Harness2::Util::File::Stream->new(name => File::Spec->catfile($auxdir, $path)),
        };
    }
    closedir($dh);

    for my $file (sort keys %$handles) {
        my $data = $handles->{$file};
        for my $line ($data->{stream}->poll()) {
            chomp($line);
            my $e = $self->_event(0, undef, time, info => [{details => $line, tag => $data->{tag}, debug => $data->{debug}, important => 1}]);
            $self->_dispatch($e);
        }
    }

    return;
}

sub _synth_job_end ($self, $job_id, $try, $file, $final_state) {
    my $fs = $final_state // {};
    my $skip;
    if (my $plan = $fs->{plan}) {
        $skip = $plan->{details} || "No reason given" unless $plan->{count};
    }

    my $task     = $self->_task_for($job_id);
    my $job_name = $task ? $task->{job_name} : $job_id;

    return $self->_event(
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

sub _note_verdict ($self, $job, $try, $end) {
    return unless $job && $end;

    my $task         = $self->_task_for($job->{job_id});
    my $retry_budget = ($task ? $task->{retry} : undef) // ($self->{+RUN} ? $self->{+RUN}->retry : 0) // 0;

    my $will_retry = $end->{fail} && (($try // 0) < $retry_budget);
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

sub _task_for ($self, $job_id) {
    for my $task (@{$self->{+TASKS} // []}) {
        return $task if ($task->{job_id} // '') eq $job_id;
    }
    return undef;
}

sub _job_for ($self, $c) {
    my $name = $c->{name} // return undef;

    for my $job (values %{$self->{+JOBS}}) {
        return $job if ($job->{rel_file} // '') eq $name;
        return $job if defined($job->{file}) && File::Spec->abs2rel($job->{file}) eq $name;
    }

    # A collector with no matching task (should not happen on the transient path)
    # gets a synthetic job record so it still rolls up.
    return $self->{+JOBS}{$name} //= {job_id => $name, file => $name, rel_file => $name, tries => 0, verdict => undef};
}

sub _dispatch ($self, $e) {
    my $settings = $self->{+SETTINGS};
    my $logger   = $self->{+LOGGER};

    my $fd = $e->{facet_data} //= {};

    my $changed = 0;
    for my $p (@{$self->{+ANNOTATE_PLUGINS}}) {
        my %inject = $p->annotate_event($e, $settings);
        next unless keys %inject;
        $changed++;

        for my $f (keys %inject) {
            if (exists $fd->{$f}) {
                if ('ARRAY' eq ref($fd->{$f})) {
                    push @{$fd->{$f}} => @{$inject{$f}};
                }
                else {
                    warn "Plugin '$p' tried to add facet '$f' via 'annotate_event()', but it is already present and not a list, ignoring plugin annotation.\n";
                }
            }
            else {
                $fd->{$f} = $inject{$f};
            }
        }
    }

    if ($logger) {
        print $logger $e->as_json, "\n";
    }

    $_->render_event($e) for @{$self->{+RENDERERS}};

    $self->{+ASSERTS_SEEN}++ if $fd->{assert};

    $_->handle_event($e, $settings) for @{$self->{+HANDLE_PLUGINS}};

    return;
}

sub _compute_final ($self) {
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

    return $final_data;
}

sub _event ($self, $job_id, $job_try, $stamp, %facets) {
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
