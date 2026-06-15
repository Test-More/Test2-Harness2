package Test2::Harness2::Collector;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;

use Test2::Harness2::Collector::JobReader;

use Test2::Harness2::Util::UUID qw/gen_uuid/;
use Test2::Harness2::Util::Queue;
use Time::HiRes qw/sleep time/;
use File::Spec;

use File::Path qw/remove_tree/;

use Test2::Harness2::Util::HashBase qw{
    <run
    <workdir
    <run_id
    <show_runner_output <truncate_runner_output <truncated_runner_output
    <settings
    <run_dir
    <runner_pid +runner_exited <persistent_runner

    <backed_up

    +runner_stdout +runner_stderr +runner_aux_dir +runner_aux_handles

    +task_file +task_queue +tasks_done +tasks
    +jobs_file +jobs_queue +jobs_done  +jobs
    +pending
    +verdicts
    +tries
    +try_will_retry

    <wait_time
    <action
};

sub init {
    my $self = shift;

    croak "'run' is required"
        unless $self->{+RUN};

    my $run_dir = File::Spec->catdir($self->{+WORKDIR}, $self->{+RUN_ID});
    die "Could not find run dir" unless -d $run_dir;
    $self->{+RUN_DIR} = $run_dir;

    $self->{+WAIT_TIME} //= 0.02;
    $self->{+VERDICTS} //= {};
    $self->{+TRIES}    //= {};
    $self->{+TRY_WILL_RETRY} //= {};

    $self->{+ACTION}->($self->_harness_event(0, undef, time, harness_run => $self->{+RUN}, harness_settings => $self->settings, about => {no_display => 1}));
}

sub process {
    my $self = shift;

    my %warning_seen;
    my $settings = $self->settings;

    while (1) {
        # $progress counts GENUINE forward motion this cycle: runner-output
        # lines, task-queue records, events emitted from a job, and jobs
        # completed/removed/aborted. A job that merely EXISTS or is STALLED
        # (poll returned nothing and it isn't done) is NOT progress -- counting
        # those is what made the old loop spin at 100% CPU between events on any
        # in-flight job (count was always > 0, so it never slept). $pending
        # tracks stalled-but-alive jobs separately so we know whether to keep
        # waiting (runner alive) or abort (runner dead).
        my $progress = 0;
        my $pending  = 0;
        $progress += $self->process_runner_output if $self->{+SHOW_RUNNER_OUTPUT};
        $progress += $self->process_tasks();

        my $jobs = $self->jobs;

        unless (keys %$jobs) {
            next if $progress;

            if ($self->persistent_runner) {
                last if $self->{+JOBS_DONE};
                last if $self->runner_done;
            }

            last if $self->runner_exited;
        }

        while(my ($job_try, $jdir) = each %$jobs) {
            my $e_count = 0;
            for my $event ($jdir->poll($self->settings->collector->max_poll_events // 1000)) {
                $self->_note_verdict($event);
                $self->{+ACTION}->($event);
                $e_count++;
            }

            $progress += $e_count;
            next if $e_count;
            my $done = $jdir->done;
            unless ($done) {
                # Stalled job: no new events and not done. Not progress -- just
                # something we're still waiting on. Track it so the no-progress
                # branch below can decide whether to keep waiting or abort.
                $pending++;
                next;
            }

            unless ($settings->debug->keep_dirs) {
                my $job_path = File::Spec->catdir($self->{+RUN_DIR}, $job_try);
                # Needed because we set the perms so that a tmpdir under it can be used.
                # This is the only remove_tree that needs it because it is the
                # only one in a process that did not initially create the dir.
                my $ok = eval {
                    chmod(0700, $job_path);
                    remove_tree($job_path, {safe => 1, keep_root => 0});
                    1;
                };
                my $err = $@;
                unless ($ok) {
                    # Cleanup failed: real work happened (we'll retry), so count
                    # it as progress and keep the job around for the next pass.
                    $progress++;
                    unless ($warning_seen{$job_path}++) {
                        my $msg = "NON-FATAL Error deleting job dir ($job_path) will try again...: $err";
                        my $e = $self->_harness_event(0, undef, time, info => [{details => $msg, tag => "INTERNAL", debug => 1, important => 1}]);
                        $self->{+ACTION}->($e);
                    }
                    next;
                }
            }

            delete $jobs->{$job_try};
            $progress++;

            # The JobReader tails one try and cannot know retry intent (its
            # done->{retry} is hardcoded 0), so consult the gatherer's own
            # decision recorded in _note_verdict. If this try failed with retry
            # budget left, a retry is coming: keep the job_id in PENDING so a
            # persistent run (which completes on empty PENDING) does not emit
            # harness_final and exit before the retry runs. The next try's job
            # entry will decrement PENDING in jobs(); only delete here once the
            # job has settled (passed, or failed with no budget).
            my $job_id = $jdir->job_id;
            delete $self->{+PENDING}->{$job_id} unless delete $self->{+TRY_WILL_RETRY}->{$job_id};
        }

        # No forward motion this cycle. Either the runner is alive and we just
        # need to wait for more output, or the runner is dead and the stalled
        # jobs will NEVER finish (no more events will ever be written to their
        # events files, so poll() returns () forever and done is never set).
        if (!$progress) {
            if ($pending && $self->runner_exited) {
                # Runner/scheduler is gone -- abort every stalled job so the run
                # rolls them up as failed instead of spinning forever waiting
                # for a harness_process_exit that will never come. After this
                # the next iteration sees empty %$jobs and exits via the
                # empty-jobs / runner_exited path above.
                $self->_abort_stalled_jobs($jobs);
                next;
            }

            last if $self->runner_exited && !$pending;
            sleep $self->{+WAIT_TIME};
        }
    }

    # One last slurp
    $self->process_runner_output if $self->{+SHOW_RUNNER_OUTPUT};

    # The loop above only exits once collection is genuinely complete: every
    # reachable job has been polled to done and removed, so VERDICTS is whole.
    # Emit the run-level harness_final + end sentinel here, on EVERY completion
    # path (normal/non-persistent, persistent-done, and halt) -- not only on
    # halt. Previously this was gated on JOBS_DONE, but JOBS_DONE is set only by
    # State::halt_run (the jobs-queue terminator), so a normally-completed run
    # never emitted a final; the (now removed) auditor process produced it
    # independently. Gate on TASKS_DONE: it is set whenever the run's task queue
    # terminator is read, which is true on every genuine completion and guards
    # against emitting a bogus "pass" final on a degraded/premature exit (e.g. a
    # runner that died before writing the task terminator).
    if ($self->{+TASKS_DONE}) {
        $self->{+ACTION}->($self->_final_event);
        $self->{+ACTION}->(undef);
    }

    remove_tree($self->{+RUN_DIR}, {safe => 1, keep_root => 0}) unless $settings->debug->keep_dirs;

    return;
}

# Called only when a cycle made no progress AND the runner process is gone.
# The stalled jobs left in %$jobs were queued (and possibly started) but their
# events files will never receive a harness_process_exit, so the JobReader will
# never set done. Synthesize the harness_job_exit + harness_job_end facets the
# renderer/rollup consume (matching JobReader::_job_exit_facet / _job_end_facet
# shapes) so each lost job renders sanely and counts as a failure, note the
# verdict so harness_final reflects it, then remove the job and clear PENDING.
sub _abort_stalled_jobs {
    my $self = shift;
    my ($jobs) = @_;

    for my $job_try (keys %$jobs) {
        my $jdir   = $jobs->{$job_try};
        my $job_id = $jdir->job_id;
        my $try    = $jdir->job_try;
        my $stamp  = time;

        my $task = $self->{+TASKS}->{$job_id};
        my $file = $jdir->file // ($task ? $task->{file} : undef);

        my $details = "Runner/scheduler exited before this job completed";

        # harness_job_exit: mirror JobReader::_job_exit_facet, but flag it as an
        # abort. exit/code = -1, signal/dumped = 0.
        my $exit_facet = {
            details => $details,
            exit    => -1,
            code    => -1,
            signal  => 0,
            dumped  => 0,
            retry   => 0,
            aborted => 1,
            job_id  => $job_id,
            job_try => $try,
            stamp   => $stamp,
        };

        # harness_job_end: mirror JobReader::_job_end_facet with fail => 1 so the
        # run-level rollup (_final_event / _note_verdict) counts it as failed.
        my $end_facet = {
            file     => $file,
            rel_file => defined($file) ? File::Spec->abs2rel($file) : undef,
            abs_file => defined($file) ? File::Spec->rel2abs($file) : undef,
            retry    => 0,
            fail     => 1,
            aborted  => 1,
            stamp    => $stamp,
        };

        my $event = $self->_harness_event(
            $job_id, $try, $stamp,
            harness_job_exit => $exit_facet,
            harness_job_end  => $end_facet,
            info             => [{details => $details, tag => "INTERNAL", debug => 1, important => 1}],
        );

        # The runner is dead; there will be no retry regardless of budget. Clear
        # PENDING BEFORE _note_verdict so it does not see leftover budget and
        # flag this failing end as "TO RETRY" (will_retry keys on PENDING).
        delete $self->{+TRY_WILL_RETRY}->{$job_id};
        delete $self->{+PENDING}->{$job_id};

        $self->_note_verdict($event);
        $self->{+ACTION}->($event);

        delete $jobs->{$job_try};
    }

    return;
}

sub runner_done {
    my $self = shift;

    return 0 if keys %{$self->{+PENDING}};
    return 1;
}

sub runner_exited {
    my $self = shift;
    my $pid = $self->{+RUNNER_PID} or return undef;

    return $self->{+RUNNER_EXITED} if $self->{+RUNNER_EXITED};

    return 0 if kill(0, $pid);

    return $self->{+RUNNER_EXITED} = 1;
}

sub process_runner_output {
    my $self = shift;

    my $out = 0;
    return $out unless $self->{+SHOW_RUNNER_OUTPUT};

    my $action = $self->{+ACTION};
    if ($self->{+TRUNCATE_RUNNER_OUTPUT} && !$self->{+TRUNCATED_RUNNER_OUTPUT}) {
        $action = sub {};
        $self->{+TRUNCATED_RUNNER_OUTPUT} = 1;
    }

    my $stdout = $self->{+RUNNER_STDOUT} //= Test2::Harness2::Util::File::Stream->new(
        name => File::Spec->catfile($self->{+WORKDIR}, 'output.log'),
    );

    for my $line ($stdout->poll()) {
        chomp($line);
        my $e = $self->_harness_event(0, undef, time, info => [{details => $line, tag => 'INTERNAL', important => 1}]);
        $action->($e);
        $out++;
    }

    my $stderr = $self->{+RUNNER_STDERR} //= Test2::Harness2::Util::File::Stream->new(
        name => File::Spec->catfile($self->{+WORKDIR}, 'error.log'),
    );

    for my $line ($stderr->poll()) {
        chomp($line);
        my $e = $self->_harness_event(0, undef, time, info => [{details => $line, tag => 'INTERNAL', debug => 1, important => 1}]);
        $action->($e);
        $out++;
    }

    my $auxdir = $self->{+RUNNER_AUX_DIR} //= File::Spec->catdir($self->{+WORKDIR}, 'aux_logs');
    return $out unless -d $auxdir;

    opendir(my $dh, $auxdir) or die "Could not open aux_logs dir: $!";
    for my $path (readdir($dh)) {
        next if $path =~ m/^\.+$/;
        next if $self->{+RUNNER_AUX_HANDLES}->{$path};

        my $tag = uc($path);
        next unless $tag =~ s/\.LOG$//;

        my $debug = 0;
        if ($tag =~ s/\W*(STDERR|STDOUT)\W*//g) {
            $debug = 1 if $1 && uc($1) eq 'STDERR';
        }

        $self->{+RUNNER_AUX_HANDLES}->{$path} = {
            tag    => $tag,
            debug  => $debug,
            stream => Test2::Harness2::Util::File::Stream->new(name => File::Spec->catfile($auxdir, $path)),
        };
    }
    closedir($dh);

    for my $file (sort keys %{$self->{+RUNNER_AUX_HANDLES}}) {
        my $data   = $self->{+RUNNER_AUX_HANDLES}->{$file};
        my $stream = $data->{stream};

        for my $line ($stream->poll()) {
            chomp($line);
            my $e = $self->_harness_event(0, undef, time, info => [{details => $line, tag => $data->{tag}, debug => $data->{debug}, important => 1}]);
            $action->($e);
            $out++;
        }
    }

    return $out;
}

sub process_tasks {
    my $self = shift;

    return 0 if $self->{+TASKS_DONE};

    my $queue = $self->tasks_queue or return 0;

    my $count = 0;
    for my $item ($queue->poll) {
        $count++;
        my ($spos, $epos, $task) = @$item;

        unless ($task) {
            $self->{+TASKS_DONE} = 1;
            last;
        }

        my $job_id = $task->{job_id} or die "No job id!";
        $self->{+TASKS}->{$job_id} = $task;
        $self->{+PENDING}->{$job_id} = 1 + ($task->{retry} || $self->run->retry || 0);

        my $e = $self->_harness_event($job_id, $task->{is_try} // 0, $task->{stamp}, 'harness_job_queued' => $task);
        $self->{+ACTION}->($e);
    }

    return $count;
}

sub send_backed_up {
    my $self = shift;
    return if $self->{+BACKED_UP}++;

    # This is an unlikely code path. If we're here, it means the last loop couldn't process any results.
    my $e = $self->_harness_event(0, undef, time, info => [{details => <<"    EOT", tag => "INTERNAL", debug => 1, important => 1}]);
*** THIS IS NOT FATAL ***

 * The collector has reached the maximum number of concurrent jobs to process.
 * Testing will continue, but some tests may be running or even complete before they are rendered.
 * All tests and events will eventually be displayed, and your final results will not be effected.

Set a higher --max-open-jobs collector setting to prevent this problem in the
future, but be advised that could result in too many open filehandles on some
systems.

This message will only be shown once.
    EOT

    $self->{+ACTION}->($e);
    return;
}

sub jobs {
    my $self = shift;

    my $jobs = $self->{+JOBS} //= {};

    return $jobs if $self->{+JOBS_DONE};

    # Don't monitor more than 'max_open_jobs' or we might have too many open file handles and crash
    # Max open files handles on a process applies. Usually this is 1024 so we
    # can't have everything open at once when we're behind.
    my $max_open_jobs = $self->settings->collector->max_open_jobs // 1024;
    my $additional_jobs_to_parse = $max_open_jobs - keys %$jobs;
    if($additional_jobs_to_parse <= 0) {
        $self->send_backed_up;
        return $jobs;
    }

    my $queue = $self->jobs_queue or return $jobs;

    for my $item ($queue->poll($additional_jobs_to_parse)) {
        my ($spos, $epos, $job) = @$item;

        unless ($job) {
            $self->{+JOBS_DONE} = 1;
            last;
        }

        my $job_id = $job->{job_id} or die "No job id!";

        die "Found job without a task!" unless $self->{+TASKS}->{$job_id};

        $self->{+PENDING}->{$job_id}--;
        delete $self->{+PENDING}->{$job_id} if $self->{+PENDING}->{$job_id} < 1;

        my $file = $job->{file};
        my $e = $self->_harness_event(
            $job_id,
            $job->{is_try},
            $job->{stamp},
            harness_job        => $job,
            harness_job_start  => {
                details => "Job $job_id started at $job->{stamp}",
                job_id  => $job_id,
                stamp   => $job->{stamp},
                file    => $file,
                rel_file => File::Spec->abs2rel($file),
                abs_file => File::Spec->rel2abs($file),
            },
            harness_job_launch => {
                stamp => $job->{stamp},
                retry => $job->{is_try},
            },
        );

        $self->{+ACTION}->($e);

        my $job_try = $job_id . '+' . $job->{is_try};

        $jobs->{$job_try} = Test2::Harness2::Collector::JobReader->new(
            job_id      => $job_id,
            job_try     => $job->{is_try} // 0,
            run_id      => $self->{+RUN_ID},
            file        => $file,
            events_file => File::Spec->catfile($self->{+RUN_DIR}, $job_try, 'events.jsonl.zst'),
        );
    }

    # The collector didn't read in all the jobs because it'd run out of file handles. We need to let the stream know we're behind.
    $self->send_backed_up if $max_open_jobs <= keys %$jobs;

    return $jobs;
}

sub _note_verdict {
    my $self = shift;
    my ($event) = @_;

    my $fd = $event->facet_data or return;

    if (my $end = $fd->{harness_job_end}) {
        my $job_id = $event->job_id;

        # Retry intent: the JobReader tails a single try's events file and cannot
        # know whether the runner will retry this try, so it hardcodes retry=0.
        # The gatherer DOES know: PENDING->{$job_id} is the remaining retry budget
        # (it starts at 1 + retry-count in process_tasks and is decremented in
        # jobs() each time a new try's job entry is read). At the moment a FAILING
        # job_end arrives, the current try's entry has already been read, so a
        # non-zero PENDING means more tries are budgeted; the runner retries every
        # failure while budget remains (Runner: is_try < retry => retry_task), so
        # a failing try with budget left WILL be retried. Mark it so the renderer
        # shows "TO RETRY" instead of "FAILED" for a non-final try.
        my $will_retry = $end->{fail} && ($self->{+PENDING}{$job_id} // 0) > 0;
        if ($will_retry) {
            $end->{retry} = 1;
        }

        # Remember the retry decision so the process loop keeps this job_id
        # "unsettled" in PENDING until the retry's try has been read (otherwise a
        # persistent run, which gates completion on runner_done -> empty PENDING,
        # would emit harness_final and exit before the retry ever ran). Settled on
        # the final try (pass, or fail with no budget left).
        $self->{+TRY_WILL_RETRY}{$job_id} = $will_retry ? 1 : 0;

        # VERDICTS is last-try-wins (keyed by job_id, overwritten each try) so it
        # always holds the FINAL verdict for the job. TRIES counts every
        # harness_job_end seen for the job_id, giving the total attempt count
        # (try 0 + each retry) independent of last-try-wins.
        $self->{+VERDICTS}{$job_id} = {
            file => $end->{file},
            fail => $end->{fail} ? 1 : 0,
            try  => $event->job_try,
            halt => $end->{halt},
        };

        $self->{+TRIES}{$job_id}++;
    }
}

# Run-level rollup. Ports the shape produced by Test2::Harness2::Auditor::finish
# (which is removed in Task 7): a harness_final facet with pass + failed/retried/
# halted/unseen lists. The test command's finalizer (App::Yath2::Command::test
# 'render') reads ONLY harness_final, so this shape is a hard contract.
sub _final_event {
    my $self = shift;

    my $final_data = {pass => 1};

    # Every job we ever queued has a TASK entry. A job that produced a verdict
    # (harness_job_end) is "seen"; one still left in PENDING with no verdict is
    # "unseen". This mirrors Auditor::finish's watchers-vs-no-watchers split.
    for my $job_id (keys %{$self->{+TASKS}}) {
        my $task = $self->{+TASKS}{$job_id};
        my $verdict = $self->{+VERDICTS}{$job_id};

        if ($verdict) {
            my $file = defined($verdict->{file}) ? File::Spec->abs2rel($verdict->{file}) : $task->{file};

            # VERDICTS is last-try-wins, so $verdict->{fail} is the FINAL
            # verdict: a job that failed try 0 but passed a retry is NOT failed.
            # NOTE: failed_subtest_tree (the old 3rd element) came from the
            # Auditor::Watcher state machine, which no longer runs in the
            # gatherer. Emit the [job_id, file] pair the finalizer iterates.
            push @{$final_data->{failed}} => [$job_id, $file] if $verdict->{fail};

            # A job that ran more than once was retried. Shape required by
            # retry.t: [uuid, tries, file, status] where tries = total attempts
            # (try 0 + retries) and status = 'YES' if it eventually passed, 'NO'
            # if every attempt failed (final verdict failed).
            my $tries = $self->{+TRIES}{$job_id} // 1;
            if ($tries > 1) {
                push @{$final_data->{retried}} => [$job_id, $tries, $file, ($verdict->{fail} ? 'NO' : 'YES')];
            }

            # A bail-out / halt reason rides through on the audited final state
            # (JobReader threads it into harness_job_end). Surface it under the
            # renderer's "Halted" section: [job_id, file, reason].
            push @{$final_data->{halted}} => [$job_id, $file, $verdict->{halt}]
                if defined($verdict->{halt}) && length($verdict->{halt});
        }
        else {
            push @{$final_data->{unseen}} => [$job_id, $task->{file}];
        }
    }

    $final_data->{pass} = 0 if $final_data->{failed} or $final_data->{unseen};

    return $self->_harness_event(0, undef, time, harness_final => $final_data);
}

sub _harness_event {
    my $self = shift;
    my ($job_id, $job_try, $stamp, %args) = @_;

    croak "Job id is required" unless defined $job_id;
    croak "Stamp is required" unless defined $stamp;

    return Test2::Harness2::Event->new(
        stamp      => $stamp,
        job_id     => $job_id,
        job_try    => $job_try,
        event_id   => gen_uuid(),
        run_id     => $self->{+RUN_ID},
        facet_data => \%args,
    );
}

sub jobs_queue {
    my $self = shift;

    return $self->{+JOBS_QUEUE} if $self->{+JOBS_QUEUE};

    my $jobs_file = $self->{+JOBS_FILE} //= File::Spec->catfile($self->{+RUN_DIR}, 'jobs.jsonl');

    return unless -f $jobs_file;

    return $self->{+JOBS_QUEUE} = Test2::Harness2::Util::Queue->new(file => $jobs_file);
}

sub tasks_queue {
    my $self = shift;

    return $self->{+TASK_QUEUE} if $self->{+TASK_QUEUE};

    my $tasks_file = $self->{+TASK_FILE} //= File::Spec->catfile($self->{+RUN_DIR}, 'queue.jsonl');

    return unless -f $tasks_file;

    return $self->{+TASK_QUEUE} = Test2::Harness2::Util::Queue->new(file => $tasks_file);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector - Module that collects test output and provides it as
an event stream.

=head1 DESCRIPTION

This module is responsible for reading and parsing the output produced by
multiple jobs running under yath.

This module is not intended for external use, it is an implementation detail
and can change at any time. Currently instances of this module are not passed
to any plugins or callbacks.

If you need a collector for a third-party command you should look at
L<App::Yath2::Command::collector>. When a command needs a collector (such as
L<App::Yath2::Command::test> does) it normally spawns a collector process by
execuing C<yath collector>. The C<start_collector()> subroutine in
L<App::Yath2::Command::test> is a good place to look for more details.

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
