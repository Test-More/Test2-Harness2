package Test2::Harness2::Renderer::Base;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use File::Spec();
use Time::HiRes qw/time/;

use Test2::Harness2::Event;
use Test2::Harness2::JobReader;
use Test2::Harness2::RunnerReader;
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
    +runner_log_streams

    <tests_seen
    <asserts_seen
    <final_data
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Renderer::Base - Reusable base that locates a collector's
recorded C<.jsonl.zst> events file from transition state and fans recorded
events out to concrete renderers.

=head1 DESCRIPTION

This is the C<§4.5> base renderer: it knows how to locate a collector's
C<events.jsonl.zst> file from the runner's transition state (a
L<Test2::Harness2::Runner::Monitor> mirror), open it B<by the absolute path the
transition carried> via L<Test2::Harness2::JobReader> /
L<Test2::Harness2::RunnerReader>, and feed the recorded events out to a list of
concrete renderers (the C<render_event> sinks --
L<Test2::Harness2::Renderer::Formatter>, L<App::Yath2::Renderer::DB>,
L<App::Yath2::Renderer::Server>) plus the logger. Concrete renderers therefore
consume B<recorded> events rather than a live broadcast.

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

The C<render_event> fan-out (C<dispatch>) to the sink renderers + logger,
including the plugin C<annotate_event> / C<handle_event> hooks.

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
    croak "renderers is required" unless $self->{+RENDERERS};

    my $plugins = delete($self->{plugins}) // [];
    $self->{+ANNOTATE_PLUGINS} = [grep { $_->can('annotate_event') } @$plugins];
    $self->{+HANDLE_PLUGINS}   = [grep { $_->can('handle_event') } @$plugins];

    $self->{+BY_UUID}            = {};
    $self->{+JOBS}               = {};
    $self->{+SERVICE_READERS}    = {};
    $self->{+AUX_HANDLES}        = {};
    $self->{+RUNNER_LOG_STREAMS} = {};
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

=item $renderer->render_run_start

Emit the run-level C<harness_run> / C<harness_settings> event plus a
C<harness_job_queued> for every task (what the gatherer used to emit from its own
init / from C<queue.jsonl>), so the C<--show-run-info> path, the formatter's
progress counters, and the log have the run context. Idempotent.

=item $renderer->feed_events_file($events_file, %args)

Locate (open by absolute path) and feed every recorded event from one
collector's C<events.jsonl.zst> through the sink renderers + logger. C<%args> map
onto the L<Test2::Harness2::JobReader> (C<job_id>, C<job_try>, C<file>). If
C<hold> is a coderef it is called with each decoded event B<before> dispatch and,
when it returns true, the event is withheld from dispatch and returned to the
caller instead (used by a subclass to hold a job's final C<harness_job_end> for
last-place rendering). Returns the list of held events.

=item $renderer->step_runner_output($monitor)

Tail the runner's own events file and each non-test service collector's events
file (located from the transition state), dispatching their (INTERNAL-shaped)
output lines, plus the flat-log + aux-log shims. Gated on
C<show_runner_output>.

=item $count = $renderer->tests_seen

=item $count = $renderer->asserts_seen

The number of test files launched and assertions seen so far.

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

# Read one collector's recorded events file BY PATH and feed every event through
# the renderers/logger. This is the §4.5 events-file location mechanic, promoted
# out of the command-only Driver so watch + archived replay can reuse it. The
# optional `hold` coderef lets a subclass withhold specific events (e.g. the
# job's final harness_job_end) for its own ordering policy.
sub feed_events_file ($self, $events_file, %args) {
    return () unless defined $events_file && length $events_file;

    my $hold = $args{hold};

    my $reader = Test2::Harness2::JobReader->new(
        job_id      => $args{job_id},
        job_try     => $args{job_try} // 0,
        run_id      => $self->{+RUN_ID},
        file        => $args{file},
        events_file => $events_file,
    );

    my @held;
    until ($reader->done) {
        my @events = $reader->poll(1000);
        last unless @events;
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

# Surface the runner's own output (runner-events.jsonl.zst) and each transient
# preload stage's output (the service collectors' events files) the same way the
# gatherer's process_runner_events did: tail each file with a RunnerReader and
# dispatch its remapped INTERNAL-shaped info lines. Tailing readers are kept per
# file across steps so appended frames are picked up live. Gated on
# show_runner_output (the --hide-runner-output display option).
#
# This is the runner/stage events-file location half of §4.5 (the part watch
# reuses to render runner/global output); the flat-log shim below is the only
# piece that still reads a non-events file and retires in the next phase.
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
        );
    }

    # Every other (non-test) service collector announces its events file over the
    # transition channel; pick those up as they appear.
    for my $uuid ($monitor->services) {
        my $c  = $monitor->collector($uuid) or next;
        my $ef = $c->{events_file}          or next;
        $readers->{$ef} //= Test2::Harness2::RunnerReader->new(
            run_id      => $self->{+RUN_ID},
            events_file => $ef,
            label       => "yath " . ($c->{name} // 'service'),
        );
    }

    for my $reader (values %$readers) {
        next if $reader->done;
        $self->dispatch($_) for $reader->poll(1000);
    }

    $self->_step_runner_logs;
    $self->_step_aux_logs;

    return;
}

=head1 PRIVATE METHODS

=over 4

=item $self->_step_runner_logs

Flat-log shim: tail the persistent runner's flat C<output.log> / C<error.log>
(the persistent runner and its preload stages are not collector-wrapped yet) and
dispatch each line as INTERNAL-shaped info. A no-op on the transient path (no
such files). Retires in the next migration phase.

=item $self->_step_aux_logs

Tail C<< $workdir/aux_logs/*.log >> -- plugin shellcall output that bypasses the
runner collector -- and dispatch each line as INTERNAL-shaped info.

=item $job = $self->job_for($collector)

Resolve (and cache) the per-job-id rollup record for a collector, keyed by the
collector's rel_file name.

=item $self->dispatch($event)

Run one harness event through annotate plugins, the logger, the renderers, and
the handle plugins (the same path the gatherer-fed render loop used).

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

# Chunk 6.1-2 compatibility shim: tail the persistent runner's flat
# output.log/error.log. The persistent runner and its preload stages are not yet
# collector-wrapped (deferred so `yath watch` keeps tailing these flat files), so
# a stage's stdout/stderr -- e.g. a broken preload's error -- lands only in these
# files, not in any collector events file. Surface each line as INTERNAL-shaped
# info, exactly as the gatherer's process_runner_logs did (stdout important;
# stderr important + debug). The files exist only on the persistent path, so the
# transient path is a no-op.
sub _step_runner_logs ($self) {
    return unless $self->{+SHOW_RUNNER_OUTPUT};
    my $dir = $self->{+WORKDIR} or return;

    my $streams = $self->{+RUNNER_LOG_STREAMS};

    for my $spec (['output.log', 0], ['error.log', 1]) {
        my ($name, $debug) = @$spec;
        my $path = File::Spec->catfile($dir, $name);
        next unless -f $path;

        my $stream = $streams->{$name} //= Test2::Harness2::Util::File::Stream->new(name => $path);
        for my $line ($stream->poll()) {
            chomp($line);
            my $e = $self->event(0, undef, time, info => [{details => $line, tag => 'INTERNAL', debug => $debug, important => 1}]);
            $self->dispatch($e);
        }
    }

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
            my $e = $self->event(0, undef, time, info => [{details => $line, tag => $data->{tag}, debug => $data->{debug}, important => 1}]);
            $self->dispatch($e);
        }
    }

    return;
}

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
    my $settings = $self->{+SETTINGS};
    my $logger   = $self->{+LOGGER};

    my $fd = $e->{facet_data} //= {};

    for my $p (@{$self->{+ANNOTATE_PLUGINS}}) {
        my %inject = $p->annotate_event($e, $settings);
        next unless keys %inject;

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
