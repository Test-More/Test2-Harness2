package App::Yath2::Renderer::Driver;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;
use Time::HiRes qw/time/;

use Test2::Harness2::Event;
use Test2::Harness2::Util qw/tinysleep/;
use App::Yath2::Log;
use App::Yath2::OutputManager;
use App::Yath2::Options::Renderer;

# Renderer driver for the new_log_refactor test command (M2 step 11+12).
# Runs in a forked child process; reads events from an on-disk live Log
# directory via App::Yath2::Log::Live, synthesizes the lifecycle facets
# the renderer chain expects (harness_run / harness_run_end /
# harness_job_queued / harness_job_start / harness_job_end /
# harness_job_exit) from the run service's run_mutation snapshots in the
# Log, and feeds everything through the existing OutputManager +
# renderer pipelines.
#
# The driver is intentionally process-local; each entry in
# RUN_STATES tracks a single run's last seen snapshot for diffing.
# The renderer-side detection logic lives here rather than in the
# renderers themselves so the renderers stay agnostic of whether
# their event source is the live Log iterator or a sealed archive.

sub run {
    my ($class, %args) = @_;

    my $logdir       = $args{logdir}      // croak "'logdir' is required";
    my $settings     = $args{settings}    // croak "'settings' is required";
    my $harness_pid  = $args{harness_pid};

    local $| = 1;
    STDERR->autoflush(1);

    my $om        = App::Yath2::OutputManager->new;
    my $renderers = App::Yath2::Options::Renderer->init_renderers($settings);
    $om->add_renderer($_) for @$renderers;

    my $log = App::Yath2::Log->new(live => $logdir);

    my %run_states;          # run_id => last seen run_data hash
    my %seen_run_start;      # run_id => 1
    my %seen_run_end;        # run_id => 1
    my $synth_queue = [];    # queue of synthesized lifecycle events to dispatch first

    # Detection state for F22 stuck-EOE timeout: once the harness pid
    # disappears (or the LIVE sentinel goes away), allow $grace seconds
    # of quiescence before bailing out and reporting an EOE bug.
    my $grace            = 10;
    my $no_progress_deadline;
    my $last_event_at    = time;
    my $live_path        = "$logdir/LIVE";

    my $exit_code = 0;
    my $bail_reason;

    while (1) {
        # 1. Drain any events synthesized from the previous tick first,
        #    so lifecycle facets land in front of the next on-disk
        #    record we surface.
        while (my $synth = shift @$synth_queue) {
            $om->dispatch($synth);
            $last_event_at = time;
        }

        my $event = $log->event(0.05);

        if ($event) {
            $last_event_at = time;
            $no_progress_deadline = undef;

            # Re-run state-diff synthesis for state-mutation events
            # before passing the underlying event downstream. The
            # synthesized lifecycle events are queued up to dispatch
            # ahead of the next on-disk record.
            $class->_maybe_synthesize_lifecycle($event, \%run_states, \%seen_run_start, \%seen_run_end, $synth_queue);

            # Pass the on-disk event itself through too, so renderers
            # that key on lower-level facets (assert/info/control/...)
            # still see them. Lifecycle synth output sits in front of
            # this event in the queue.
            unshift @$synth_queue, $class->_blessed_event($event);
            next;
        }

        # No event right now. Check EOE first.
        if ($log->EOE) {
            last;
        }

        # F22: detect stuck iterator. If harness pid is gone or the LIVE
        # sentinel disappeared and EOE is still false, give the iterator
        # 10 seconds of grace, then bail with a clear error.
        my $harness_gone = $harness_pid && !kill(0 => $harness_pid);
        my $live_gone    = !-e $live_path;
        if ($harness_gone || $live_gone) {
            $no_progress_deadline //= time + $grace;
            if (time >= $no_progress_deadline) {
                $bail_reason = $harness_gone
                    ? "harness pid $harness_pid is gone"
                    : "LIVE sentinel disappeared";
                $exit_code = 2;
                last;
            }
        }
        else {
            $no_progress_deadline = undef;
        }

        # Tiny sleep to avoid busy spin when the iterator returned
        # nothing and EOE is still false.
        tinysleep(0.05);
    }

    # Drain anything left in the synth queue post-loop.
    while (my $synth = shift @$synth_queue) {
        $om->dispatch($synth);
    }

    if (defined $bail_reason) {
        print STDERR
            "ERROR: EOE logic bug -- $bail_reason, no new events, but \$log->EOE still false. Please report this issue.\n";
    }

    $om->end_of_events;
    $om->finish;

    return $exit_code;
}

sub _blessed_event {
    my ($class, $event) = @_;
    return $event if blessed($event) && $event->isa('Test2::Harness2::Event');
    my %copy = %$event;
    $copy{facet_data} //= {};
    return Test2::Harness2::Event->new(\%copy);
}

# Inspect an on-disk event for state-snapshot signals; if found, run the
# state-diff and push lifecycle events onto $synth_queue.
sub _maybe_synthesize_lifecycle {
    my ($class, $event, $run_states, $seen_run_start, $seen_run_end, $synth_queue) = @_;

    my $fd = ref($event) eq 'HASH' ? $event->{facet_data}
           : (blessed($event) ? $event->facet_data : undef);
    return unless ref($fd) eq 'HASH';

    my $h = $fd->{harness};
    return unless ref($h) eq 'HASH';

    # The run service emits run_mutation events carrying a full state
    # snapshot in run_data on every state change. Consume those for
    # diff-based lifecycle synthesis. run_queued also carries an
    # initial Run snapshot we treat the same way (used for the very
    # first harness_run / harness_job_queued events).
    my $kind = $h->{kind} // '';
    my $rd;
    if ($kind eq 'run_mutation' || $kind eq 'run_queued') {
        $rd = $h->{run_data};
    }

    if (ref($rd) eq 'HASH') {
        my $rid = $rd->{run_id} // $h->{run_id};
        return unless defined $rid;
        $class->_apply_run_state($rid, $rd, $run_states, $seen_run_start, $seen_run_end, $synth_queue);
        return;
    }

    # run_completed: terminal flip. The collector_report facet on the
    # same event (top-level facet_data.collector_report when the run
    # service emits one alongside) gives us pass / pass_count /
    # fail_count / timing.
    if (defined $h->{run_completed}) {
        my $rc = $h->{run_completed};
        my $rid = $rc->{run_id} // $h->{run_id};
        return unless defined $rid;

        return if $seen_run_end->{$rid}++;

        my $cr = $fd->{collector_report} // $h->{collector_report} // {};
        my %re = (
            run_id     => $rid,
            pass       => exists $cr->{pass} ? ($cr->{pass} ? 1 : 0) : 1,
            pass_count => $cr->{passed_jobs} // 0,
            fail_count => $cr->{failed_jobs} // 0,
            stamp      => $rc->{stamp} // time,
        );
        $re{wall_time}            = $cr->{ended_at} - $cr->{started_at}
            if defined $cr->{ended_at} && defined $cr->{started_at};

        push @$synth_queue, Test2::Harness2::Event->new({
            facet_data => {
                harness_run_end => \%re,
                harness_run     => {run_id => $rid},
            },
        });
        return;
    }

    return;
}

# Diff $state vs the prior snapshot for $rid; push synthesized
# lifecycle events onto $synth_queue. Pruned port of
# App::Yath2::Streamer::Base::_apply_run_state -- kept separate so
# the renderer driver does not pull in the Streamer abstraction.
sub _apply_run_state {
    my ($class, $rid, $state, $run_states, $seen_run_start, $seen_run_end, $synth_queue) = @_;

    my $prior = $run_states->{$rid};
    $run_states->{$rid} = $state;

    unless ($seen_run_start->{$rid}++) {
        push @$synth_queue, Test2::Harness2::Event->new({
            facet_data => {
                harness_run => _harness_run_facet($state),
            },
        });
    }

    my $prior_results = ($prior && ref($prior->{results}) eq 'HASH') ? $prior->{results} : {};
    my $results       = ref($state->{results}) eq 'HASH' ? $state->{results} : {};

    my @jobs = sort {
        (($results->{$a}{queued_at} // 0) <=> ($results->{$b}{queued_at} // 0))
            || ($a cmp $b)
    } keys %$results;

    for my $jid (@jobs) {
        my $now = $results->{$jid};
        my $was = $prior_results->{$jid};

        if (!$was && defined $now->{queued_at}) {
            push @$synth_queue, Test2::Harness2::Event->new({
                facet_data => {
                    harness_job_queued => {
                        job_id   => $jid,
                        file     => $now->{abs_file},
                        abs_file => $now->{abs_file},
                        rel_file => $now->{rel_file},
                        stamp    => $now->{queued_at},
                    },
                },
            });
        }

        if (defined $now->{started_at} && !($was && defined $was->{started_at})) {
            push @$synth_queue, Test2::Harness2::Event->new({
                facet_data => {
                    harness_job_start => {
                        job_id   => $jid,
                        file     => $now->{abs_file},
                        abs_file => $now->{abs_file},
                        rel_file => $now->{rel_file},
                        stamp    => $now->{started_at},
                        details  => "Launched " . ($now->{rel_file} // $jid) . " as job $jid.",
                    },
                },
            });
        }

        if (defined $now->{completed_at} && !($was && defined $was->{completed_at})) {
            push @$synth_queue, Test2::Harness2::Event->new({
                facet_data => {
                    harness_job_end => {
                        job_id   => $jid,
                        file     => $now->{abs_file} // $now->{file},
                        abs_file => $now->{abs_file},
                        rel_file => $now->{rel_file},
                        fail     => $now->{pass} ? 0 : 1,
                        stamp    => $now->{completed_at},
                        (defined $now->{exit}  ? (exit  => $now->{exit})  : ()),
                        (defined $now->{codes} ? (codes => $now->{codes}) : ()),
                        (defined $now->{times} ? (times => $now->{times}) : ()),
                    },
                    harness_job_exit => {
                        job_id => $jid,
                        (defined $now->{exit}  ? (exit  => $now->{exit})  : ()),
                        (defined $now->{codes} ? (codes => $now->{codes}) : ()),
                        stamp => $now->{completed_at},
                    },
                },
            });
        }
    }

    my $complete =
        (defined $state->{state} && $state->{state} eq 'complete')
        || (ref($state->{pending}) eq 'ARRAY' && ref($state->{running}) eq 'ARRAY'
            && !@{$state->{pending}} && !@{$state->{running}} && %$results);

    if ($complete && !$seen_run_end->{$rid}++) {
        my $stamp = _max_completed_at($results) // time;
        push @$synth_queue, Test2::Harness2::Event->new({
            facet_data => {
                harness_run_end => _harness_run_end_facet($rid, $state),
                harness_run     => _harness_run_facet($state),
            },
        });
    }

    return;
}

sub _harness_run_facet {
    my ($state) = @_;
    return {
        run_id => $state->{run_id},
        (defined $state->{created_at}      ? (created_at => $state->{created_at})        : ()),
        (ref($state->{pending}) eq 'ARRAY' ? (pending    => [@{$state->{pending}}])      : ()),
        (ref($state->{running}) eq 'ARRAY' ? (running    => [@{$state->{running}}])      : ()),
        (ref($state->{done})    eq 'ARRAY' ? (done       => [@{$state->{done}}])         : ()),
    };
}

sub _harness_run_end_facet {
    my ($rid, $state) = @_;

    my $results  = ref($state->{results}) eq 'HASH' ? $state->{results} : {};
    my $all_pass = 1;
    my ($fail_count, $pass_count) = (0, 0);
    my @cpu_agg     = (0, 0, 0, 0);
    my $have_times  = 0;
    my $cum_job_wall = 0;
    my $have_wall    = 0;

    for my $jid (keys %$results) {
        next unless defined $results->{$jid}{completed_at};
        if ($results->{$jid}{pass}) { $pass_count++ }
        else                        { $fail_count++; $all_pass = 0 }
        if (my $t = $results->{$jid}{child_times}) {
            $cpu_agg[$_] += $t->[$_] for 0 .. 3;
            $have_times = 1;
        }
        if (defined(my $w = $results->{$jid}{child_wall})) {
            $cum_job_wall += $w;
            $have_wall = 1;
        }
    }

    my $stamp     = _max_completed_at($results) // time;
    my $wall_time = defined $state->{created_at} ? ($stamp - $state->{created_at}) : undef;

    my %timing;
    $timing{wall_time}            = $wall_time     if defined $wall_time;
    $timing{cumulative_job_time}  = $cum_job_wall  if $have_wall;

    if ($have_times) {
        my $cpu_total = $cpu_agg[0] + $cpu_agg[1] + $cpu_agg[2] + $cpu_agg[3];
        $timing{cpu_times} = \@cpu_agg;
        $timing{cpu_total} = $cpu_total;
        $timing{cpu_usage}
            = ($wall_time && $wall_time > 0) ? int($cpu_total / $wall_time * 100) : 0;
    }

    return {
        run_id     => $rid,
        pass       => $all_pass ? 1 : 0,
        pass_count => $pass_count,
        fail_count => $fail_count,
        stamp      => $stamp,
        %timing,
    };
}

sub _max_completed_at {
    my ($results) = @_;
    my $max;
    for my $jid (keys %$results) {
        my $t = $results->{$jid}{completed_at};
        next unless defined $t;
        $max = $t if !defined $max || $t > $max;
    }
    return $max;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Renderer::Driver - Drive the renderer pipeline from a live on-disk Log.

=head1 SYNOPSIS

    use App::Yath2::Renderer::Driver;

    my $exit = App::Yath2::Renderer::Driver->run(
        logdir      => "$workdir/logs",
        settings    => $settings,
        harness_pid => $harness_pid,
    );

=head1 DESCRIPTION

The renderer driver runs in a forked child of the C<yath test> command.
It opens the workdir's on-disk Log via L<App::Yath2::Log/new(live =E<gt> ...)>,
iterates events, synthesizes the lifecycle facets renderers expect
(C<harness_run>, C<harness_run_end>, C<harness_job_queued>,
C<harness_job_start>, C<harness_job_end>, C<harness_job_exit>) from the
run service's per-mutation snapshots, and feeds everything through
L<App::Yath2::OutputManager>.

This replaces the old C<App::Yath2::Streamer::Live> based pipeline:
the renderer no longer consumes IPC state messages, only on-disk
events. The test command's parent process still subscribes to the
harness IPC bus for fast-path pass/fail decisions independently.

=head1 SOURCE

L<https://github.com/Test-More/Test2-Harness>

=cut
