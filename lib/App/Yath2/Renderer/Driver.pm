package App::Yath2::Renderer::Driver;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;
use Time::HiRes qw/time/;

use Test2::Harness2::Event;
use Test2::Harness2::Util qw/tinysleep/;
use App::Yath2::Log;
use App::Yath2::OutputManager;
use App::Yath2::Options::Renderer;

# Renderer driver for the test command. Runs in a forked child process;
# reads events from an on-disk live Log directory via
# App::Yath2::Log::Live, synthesizes the lifecycle facets
# the renderer chain expects (harness_run / harness_run_end /
# harness_job_queued / harness_job_start / harness_job_end /
# harness_job_exit) from the run service's skinny transition events
# (run_queued / run_started / job_started / job_completed /
# run_completed) plus per-job spec.jsonl / report.jsonl artifact
# lookups, and feeds everything through the existing OutputManager +
# renderer pipelines.
#
# The renderer-side detection logic lives here rather than in the
# renderers themselves so the renderers stay agnostic of whether
# their event source is the live Log iterator or a sealed archive.
# Per-run state is small: queue/start/end stamps, the job_ids list
# from run_queued, and a lazy cache of per-job spec/report rows
# (keyed by "<jid>/<try>") so artifact lookups happen at most once
# per job per try regardless of how many transition events arrive.

# Function too long, break it up
sub run {
    my ($class, %args) = @_;

    my $settings     = $args{settings}    // croak "'settings' is required";
    my $harness_pid  = $args{harness_pid};
    my $log          = $args{log};
    my $logdir       = $args{logdir};
    # Optional: a specific run_id whose completion should end the
    # driver loop. Used by `yath run`, which dials into a persistent
    # daemon whose log iterator never reaches EOE on its own.
    my $stop_run_id  = $args{stop_run_id};

    croak "'log' or 'logdir' is required"
        unless $log || (defined $logdir && length $logdir);

    local $| = 1;
    STDERR->autoflush(1);

    my $om        = App::Yath2::OutputManager->new;
    my $renderers = App::Yath2::Options::Renderer->init_renderers($settings);
    $om->add_renderer($_) for @$renderers;

    $log //= App::Yath2::Log->new(live => $logdir);
    my $is_live = $log->can('is_live') ? $log->is_live : 0;

    my %run_states;          # run_id => { queued_at, started_at, job_ids, jobs => { "$jid/$try" => { spec, report } } }
    my %seen_run_start;      # run_id => 1
    my %seen_run_end;        # run_id => 1
    my $synth_queue = [];    # queue of synthesized lifecycle events to dispatch first

    # Detection state for the stuck-EOE timeout (live mode only): once
    # the harness pid disappears (or the LIVE sentinel goes away),
    # allow $grace seconds of quiescence before bailing out and
    # reporting an EOE bug. Sealed mode never polls -- the iterator is
    # walked synchronously and EOE flips true once the readers drain.
    my $grace            = $args{grace} // 10;
    my $no_progress_deadline;
    my $last_event_at    = time;
    my $live_path        = (defined $logdir && length $logdir) ? "$logdir/LIVE" : undef;

    my $exit_code = 0;
    my $bail_reason;

    # Poll/timeout cadence depends on mode. Sealed mode passes timeout=0
    # so the iterator returns whatever is buffered immediately and we
    # exit as soon as the stack drains. Live mode passes a small
    # positive timeout to amortize syscall overhead.
    my $poll_timeout = $is_live ? 0.05 : 0;

    while (1) {
        # 1. Drain any events synthesized from the previous tick first,
        #    so lifecycle facets land in front of the next on-disk
        #    record we surface.
        while (my $synth = shift @$synth_queue) {
            $om->dispatch($synth);
            $last_event_at = time;
        }

        my $event = $log->event($poll_timeout);

        if ($event) {
            $last_event_at = time;
            $no_progress_deadline = undef;

            # In persistent-daemon mode the log accumulates events
            # from every run that ever queued on this daemon. Skip
            # events tagged with a run_id that is not ours. Events
            # with no run_id (e.g. service_started for the harness)
            # pass through; they predate any run and are still part
            # of the renderer's expected lifecycle.
            if (defined $stop_run_id) {
                my $ev_rid = $class->_event_run_id($event);
                next if defined $ev_rid && $ev_rid ne $stop_run_id;
            }

            # Re-run lifecycle synthesis for transition events
            # before passing the underlying event downstream. The
            # synthesized lifecycle events are queued up to dispatch
            # ahead of the next on-disk record.
            $class->_maybe_synthesize_lifecycle($event, $log, \%run_states, \%seen_run_start, \%seen_run_end, $synth_queue);

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

        # In persistent-daemon mode the iterator's LIVE sentinel never
        # disappears, so EOE never flips. Exit cleanly once the
        # specific run we were dispatched for has completed and its
        # lifecycle synth has been drained.
        last if defined $stop_run_id
             && $seen_run_end{$stop_run_id}
             && !@$synth_queue;

        # Sealed mode: no polling, no live sentinel. If EOE is false
        # but no event came back, treat as drained and exit.
        unless ($is_live) {
            last;
        }

        # Detect stuck iterator. If harness pid is gone or the LIVE
        # sentinel disappeared and EOE is still false, give the iterator
        # 10 seconds of grace, then bail with a clear error.
        my $harness_gone = $harness_pid && !kill(0 => $harness_pid);
        my $live_gone    = defined($live_path) && !-e $live_path;
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

# Extract a run_id from an event by scanning the facets that carry one.
# Returns undef when no facet identifies a run (e.g. service_started for
# the harness service, which predates any run). Used by `yath run` to
# skip events that belong to other runs on a persistent daemon's log.
sub _event_run_id {
    my ($class, $event) = @_;

    my $fd = ref($event) eq 'HASH' ? $event->{facet_data}
           : (blessed($event) ? $event->facet_data : undef);
    return undef unless ref($fd) eq 'HASH';

    for my $facet (qw{
        harness
        harness_run
        harness_run_queued
        harness_run_start
        harness_run_end
        harness_job_queued
        harness_job_start
        harness_job_end
        harness_job_exit
        harness_collector_start
        harness_collector_end
    }) {
        my $f = $fd->{$facet};
        next unless ref($f) eq 'HASH';
        return $f->{run_id} if defined $f->{run_id};
    }

    return undef;
}

# Inspect an on-disk event for a transition signal; on hit, push the
# corresponding lifecycle facets onto $synth_queue, lazy-loading per-job
# spec/report artifacts as needed.
sub _maybe_synthesize_lifecycle {
    my ($class, $event, $log, $run_states, $seen_run_start, $seen_run_end, $synth_queue) = @_;

    my $fd = ref($event) eq 'HASH' ? $event->{facet_data}
           : (blessed($event) ? $event->facet_data : undef);
    return unless ref($fd) eq 'HASH';

    my $h = $fd->{harness};
    return unless ref($h) eq 'HASH';

    my $kind = $h->{kind} // '';

    if ($kind eq 'run_queued') {
        my $rid = $h->{run_id};
        return unless defined $rid;

        my $rs = $run_states->{$rid} //= {jobs => {}};
        $rs->{queued_at} = $h->{queued_at};
        $rs->{job_ids}   = ref($h->{job_ids}) eq 'ARRAY' ? [@{$h->{job_ids}}] : [];

        unless ($seen_run_start->{$rid}++) {
            push @$synth_queue, Test2::Harness2::Event->new({
                facet_data => {
                    harness_run => {
                        run_id     => $rid,
                        (defined $h->{queued_at} ? (created_at => $h->{queued_at}) : ()),
                        pending    => [@{$rs->{job_ids}}],
                        running    => [],
                        done       => [],
                    },
                },
            });
        }

        for my $jid (@{$rs->{job_ids}}) {
            my $spec = _job_spec($log, $rid, $jid, 0, $rs);
            push @$synth_queue, Test2::Harness2::Event->new({
                facet_data => {
                    harness_job_queued => {
                        job_id   => $jid,
                        file     => $spec->{abs_file} // $spec->{rel_file},
                        abs_file => $spec->{abs_file},
                        rel_file => $spec->{rel_file},
                        stamp    => $spec->{queued_at} // $h->{queued_at},
                    },
                },
            });
        }
        return;
    }

    if ($kind eq 'run_started') {
        my $rid = $h->{run_id};
        return unless defined $rid;
        ($run_states->{$rid} //= {jobs => {}})->{started_at} = $h->{started_at};
        return;
    }

    if ($kind eq 'job_started') {
        my $info = $h->{job_info} // {};
        my $rid  = $info->{run_id} // $h->{run_id};
        my $jid  = $info->{job_id};
        my $try  = $info->{job_try} // 1;
        return unless defined $rid && defined $jid;

        my $rs   = $run_states->{$rid} //= {jobs => {}};
        my $spec = _job_spec($log, $rid, $jid, $try, $rs);
        my $stamp = $h->{stamp} // $spec->{started_at} // time;

        push @$synth_queue, Test2::Harness2::Event->new({
            facet_data => {
                harness_job_start => {
                    job_id   => $jid,
                    file     => $spec->{abs_file} // $spec->{rel_file},
                    abs_file => $spec->{abs_file},
                    rel_file => $spec->{rel_file},
                    stamp    => $stamp,
                    details  => "Launched " . ($spec->{rel_file} // $jid) . " as job $jid.",
                },
            },
        });
        return;
    }

    if ($kind eq 'job_completed') {
        my $info = $h->{job_info} // {};
        my $rid  = $info->{run_id} // $h->{run_id};
        my $jid  = $info->{job_id};
        my $try  = $info->{job_try} // 1;
        return unless defined $rid && defined $jid;

        my $rs     = $run_states->{$rid} //= {jobs => {}};
        my $spec   = _job_spec($log, $rid, $jid, $try, $rs);
        my $report = _job_report($log, $rid, $jid, $try, $rs);
        my $stamp  = $h->{stamp} // $report->{ended_at} // time;
        my $pass   = exists $h->{pass} ? ($h->{pass} ? 1 : 0)
                   : ($report->{pass}  ? 1 : 0);

        my %end_facet = (
            job_id   => $jid,
            file     => $spec->{abs_file} // $spec->{rel_file},
            abs_file => $spec->{abs_file},
            rel_file => $spec->{rel_file},
            fail     => $pass ? 0 : 1,
            stamp    => $stamp,
        );
        $end_facet{exit}  = $report->{exit}         if defined $report->{exit};
        $end_facet{codes} = $report->{exit_decoded} if defined $report->{exit_decoded};
        $end_facet{times} = $report->{times}        if defined $report->{times};

        my %exit_facet = (job_id => $jid, stamp => $stamp);
        $exit_facet{exit}  = $report->{exit}         if defined $report->{exit};
        $exit_facet{codes} = $report->{exit_decoded} if defined $report->{exit_decoded};

        push @$synth_queue, Test2::Harness2::Event->new({
            facet_data => {
                harness_job_end  => \%end_facet,
                harness_job_exit => \%exit_facet,
            },
        });
        return;
    }

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
        $re{wall_time} = $cr->{ended_at} - $cr->{started_at}
            if defined $cr->{ended_at} && defined $cr->{started_at};

        # Aggregate per-job timing from the cached report rows. Renderer
        # used to read this off the run service's run_mutation snapshot;
        # since that channel is gone, we walk whatever per-job reports
        # we cached during the run.
        my $rs = $run_states->{$rid} // {};
        if (my $jobs = $rs->{jobs}) {
            my @cpu_agg     = (0, 0, 0, 0);
            my $have_times  = 0;
            my $cum_job_wall = 0;
            my $have_wall    = 0;
            for my $key (keys %$jobs) {
                my $rep = $jobs->{$key}{report} // {};
                if (my $t = $rep->{child_times}) {
                    $cpu_agg[$_] += $t->[$_] for 0 .. 3;
                    $have_times = 1;
                }
                if (defined(my $w = $rep->{child_wall})) {
                    $cum_job_wall += $w;
                    $have_wall = 1;
                }
            }

            $re{cumulative_job_time} = $cum_job_wall if $have_wall;
            if ($have_times && defined $re{wall_time} && $re{wall_time} > 0) {
                my $cpu_total = $cpu_agg[0] + $cpu_agg[1] + $cpu_agg[2] + $cpu_agg[3];
                $re{cpu_times} = \@cpu_agg;
                $re{cpu_total} = $cpu_total;
                $re{cpu_usage} = int($cpu_total / $re{wall_time} * 100);
            }
        }

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

# Lazy per-job spec lookup, cached on $rs->{jobs}{"$jid/$try"}{spec}.
# Returns a hash with abs_file / rel_file / queued_at / started_at
# (any subset, depending on what the spec actually carried). Empty
# hash on lookup failure -- caller must be defensive.
sub _job_spec {
    my ($log, $rid, $jid, $try, $rs) = @_;
    $try //= 1;
    my $key = "$jid/$try";
    $rs->{jobs}{$key} //= {};
    return $rs->{jobs}{$key}{spec} if $rs->{jobs}{$key}{spec};

    my $row;
    eval {
        my $a    = $log->artifacts($rid, $jid, $try) or return;
        my $iter = $a->spec_iter                     or return;
        $row     = $iter->next;
        1;
    };
    $row //= {};

    my %out;
    $out{abs_file}   = $row->{absolute}    if defined $row->{absolute};
    $out{rel_file}   = $row->{relative}    if defined $row->{relative};
    $out{queued_at}  = $row->{queued_at}   if defined $row->{queued_at};
    $out{started_at} = $row->{started_at}  if defined $row->{started_at};

    return $rs->{jobs}{$key}{spec} = \%out;
}

# Lazy per-job report lookup, cached on $rs->{jobs}{"$jid/$try"}{report}.
# Returns the raw report row (exit / exit_decoded / pass / pass_count /
# fail_count / ended_at / times / child_times / child_wall / etc.).
# Empty hash on lookup failure.
sub _job_report {
    my ($log, $rid, $jid, $try, $rs) = @_;
    $try //= 1;
    my $key = "$jid/$try";
    $rs->{jobs}{$key} //= {};
    return $rs->{jobs}{$key}{report} if $rs->{jobs}{$key}{report};

    my $row;
    eval {
        my $a    = $log->artifacts($rid, $jid, $try) or return;
        my $iter = $a->report_iter                   or return;
        $row     = $iter->next;
        1;
    };
    return $rs->{jobs}{$key}{report} = $row // {};
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Renderer::Driver - Drive the renderer pipeline from a live on-disk Log.

=head1 SYNOPSIS

    use App::Yath2::Renderer::Driver;

    # Live mode (the test command's main use):
    my $exit = App::Yath2::Renderer::Driver->run(
        logdir      => "$workdir/logs",
        settings    => $settings,
        harness_pid => $harness_pid,
    );

    # Sealed mode (replay command):
    my $exit = App::Yath2::Renderer::Driver->run(
        log      => $log,            # any App::Yath2::Log backend
        settings => $settings,
    );

=head1 DESCRIPTION

The renderer driver runs in a forked child of the C<yath test> command.
It opens the workdir's on-disk Log via L<App::Yath2::Log/new(live =E<gt> ...)>,
iterates events, synthesizes the lifecycle facets renderers expect
(C<harness_run>, C<harness_run_end>, C<harness_job_queued>,
C<harness_job_start>, C<harness_job_end>, C<harness_job_exit>) from the
run service's per-mutation snapshots, and feeds everything through
L<App::Yath2::OutputManager>.

The renderer consumes only on-disk events. The test command's
parent process subscribes to the harness IPC bus for fast-path
pass/fail decisions independently. The driver is also reused by
sealed-mode consumers (replay command) -- pass C<log =E<gt> $log>
to use a pre-built backend, or C<logdir =E<gt> $dir> to open a
live workdir.

=head1 SOURCE

L<https://github.com/Test-More/Test2-Harness>

=cut
