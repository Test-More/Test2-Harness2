package Test2::Harness2::Collector::Auditor::Test;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;
use List::Util qw/first max/;
use Time::HiRes qw/time/;

use Test2::Harness2::Util qw/hub_truth parse_exit/;
use Test2::Harness2::Event;

use Role::Tiny::With;
with 'Test2::Harness2::Role::Auditor';

# Auditor::Test absorbs the IPC duties that used to live in
# TestObserver (post new_log_refactor M2 step 4+5):
#
#   test_job_started     emitted from startup($collector)
#   test_job_diagnosing  emitted from audit_event on the first
#                         diagnostic facet (info important/debug
#                         or STDERR-sourced)
#   test_job_failing     emitted from audit_event on the first
#                         failing assertion / error-without-amnesty
#   test_job_completed   emitted from shutdown($collector) (which
#                         also forwards the final state hash per F18)
#   job_release          emitted from shutdown alongside
#                         test_job_completed
#
# All emissions go through the collector's send_ipc method so the
# auditor never holds its own IPC client.

use Object::HashBase qw{
    <run_id
    <job_id
    <job_try
    <ipcm_info
    -assertion_count
    -exit
    -plan
    +fail
    -_errors
    -_failures
    -_sub_failures
    -_plans
    -nested
    -subtests
    -numbers
    -halt
    -failed_subtest_tree
    -passing_subtests
    -failing_subtests
    -top_level_subtests

    +_collector
    +_ipc_run
    +_ipc_harness
    +_test_pid
    +_collector_pid
    +_emitted_started
    +_emitted_diagnosing
    +_emitted_failing
    +_emitted_completed
};

# Attribute reference:
#   run_id              -- identifier of the run this auditor belongs to (used in harness_job_exit).
#   job_id              -- identifier of the job (test) this auditor belongs to (used in harness_job_exit).
#   job_try             -- 0-based attempt number for this job (used in harness_job_exit).
#   assertion_count     -- total assertions seen so far (passing + failing, sans amnesty bookkeeping).
#   exit                -- raw wait-status integer captured from the harness_process_exit facet, undef until seen.
#   plan                -- the plan facet hashref once observed (count / details / etc.), undef otherwise.
#   fail                -- latched flag set true once fail() determines the run cannot pass; sticky thereafter.
#   _errors             -- count of error/control facets that flagged failure or halt.
#   _failures           -- count of failing assertions not covered by amnesty (todo).
#   _sub_failures       -- count of subtests whose own auditing concluded they failed.
#   _plans              -- number of plan facets seen; >1 triggers a "too many plans" failure.
#   nested              -- subtest nesting depth this auditor represents; 0 for the top-level run.
#   subtests            -- map of nested-depth -> in-progress subtest state (start event + collected child facets).
#   numbers             -- map of TAP assertion-number -> times-seen, for duplicate / missing-number detection.
#   halt                -- human-readable bail-out reason if a control facet halted the run, undef otherwise.
#   failed_subtest_tree -- nested arrayref describing the path through any failed subtests for diagnostics.
#   passing_subtests    -- arrayref of names of subtests that have passed at this auditor's nesting level.
#   failing_subtests    -- arrayref of names of subtests that have failed at this auditor's nesting level.

sub init {
    my $self = shift;

    croak "'ipcm_info' is a required attribute"
        unless defined $self->{+IPCM_INFO};

    $self->{+_FAILURES}       = 0;
    $self->{+_ERRORS}         = 0;
    $self->{+_SUB_FAILURES}   = 0;
    $self->{+_PLANS}          = 0;
    $self->{+ASSERTION_COUNT} = 0;

    $self->{+NUMBERS}             = {};
    $self->{+SUBTESTS}            = {};
    $self->{+PASSING_SUBTESTS}    = [];
    $self->{+FAILING_SUBTESTS}    = [];
    $self->{+TOP_LEVEL_SUBTESTS} = [];

    $self->{+NESTED} //= 0;
}

sub set_process_info {
    my ($self, %info) = @_;
    $self->{+RUN_ID}  = $info{run_id}  if exists $info{run_id};
    $self->{+JOB_ID}  = $info{job_id}  if exists $info{job_id};
    $self->{+JOB_TRY} = $info{job_try} if exists $info{job_try};
    return;
}

sub set_ipcm_info {
    my ($self, $info) = @_;
    $self->{+IPCM_INFO} = $info;
    return;
}

sub passing { !$_[0]->failing }
sub failing { $_[0]->fail_count ? 1 : 0 }

sub pass { !$_[0]->fail }

sub fail {
    my $self = shift;
    return $self->{+FAIL}     if $self->{+FAIL};
    return $self->{+FAIL} = 1 if $self->fail_error_facet_list;
    return 0;
}

sub fail_count {
    my $self  = shift;
    my $count = $self->{+_FAILURES} + $self->{+_ERRORS} + $self->{+_SUB_FAILURES};
    $count++ if $self->{+HALT};
    $count++ if defined($self->{+EXIT}) && $self->{+EXIT} != 0;
    $count++ if !$count                 && $self->{+FAIL};
    return $count;
}

sub pass_count {
    my $self   = shift;
    my $passes = $self->{+ASSERTION_COUNT} - $self->{+_FAILURES};
    return $passes < 0 ? 0 : $passes;
}

sub has_exit { defined $_[0]->{+EXIT} }
sub has_plan { defined $_[0]->{+PLAN} }

# Final-state hash for downstream consumers (collector report row,
# IPC test_job_completed payload). Includes the top-level subtest
# summary (per F9: name / pass / count_pass / count_fail). Order in
# the subtests array is insertion order (as seen in the stream).
sub final_state {
    my $self = shift;

    my %state = (
        pass            => $self->pass ? 1 : 0,
        fail_count      => $self->fail_count,
        pass_count      => $self->pass_count,
        assertion_count => $self->{+ASSERTION_COUNT} // 0,
        exit            => $self->{+EXIT},
        subtests        => [@{$self->{+TOP_LEVEL_SUBTESTS} // []}],
    );

    $state{plan} = $self->{+PLAN} if defined $self->{+PLAN};
    $state{halt} = $self->{+HALT} if defined $self->{+HALT};

    return \%state;
}

sub audit_event {
    my $self = shift;
    my ($event) = @_;

    $event->{facet_data} //= {};

    # Stream-transition IPC: emit test_job_diagnosing on the first
    # diagnostic facet, test_job_failing on the first failing
    # assertion / error-without-amnesty. Done before _audit so the
    # IPC fires the moment the auditor actually saw the event.
    my $f = $event->{facet_data};
    if ($f) {
        unless ($self->{+_EMITTED_FAILING}) {
            $self->_emit_failing if $self->_event_is_failing($f);
        }
        unless ($self->{+_EMITTED_DIAGNOSING}) {
            $self->_emit_diagnosing if $self->_event_is_diagnostic($f);
        }
    }

    my @out;
    for my $se ($self->_audit($event)) {
        $se->{facet_data} //= {} if ref($se);
        delete $se->{facet_data}->{harness}->{closed_by}
            if $se->{facet_data} && $se->{facet_data}->{harness};
        push @out => $se;
    }

    return @out;
}

# Lifecycle hooks called by the collector. Both may return zero or
# more events to forward through the write phase; today both return
# nothing, but we keep the contract for symmetry with how the rest
# of the harness drives lifecycle methods.

sub startup {
    my ($self, $collector) = @_;
    return unless $collector;

    $self->{+_COLLECTOR}     = $collector;
    $self->{+_IPC_RUN}       = $collector->ipc_run;
    $self->{+_IPC_HARNESS}   = $collector->ipc_harness;
    $self->{+_TEST_PID}      = $collector->child_pid;
    $self->{+_COLLECTOR_PID} = $$;

    $self->_emit_started;

    return;
}

sub shutdown {
    my ($self, $collector) = @_;
    $self->{+_COLLECTOR} //= $collector;

    $self->_emit_completed unless $self->{+_EMITTED_COMPLETED};
    return;
}

# Has the collector reached a state where the run can release this
# job's resources? Used by the shutdown path to decide whether to
# emit job_release in addition to test_job_completed.
sub _event_is_failing {
    my ($self, $f) = @_;

    if (my $assert = $f->{assert}) {
        return 1 if !$assert->{pass} && !($f->{amnesty} && @{$f->{amnesty}});
    }

    if (my $errors = $f->{errors}) {
        return 1 if first { $_->{fail} } @$errors;
    }

    if (my $ctrl = $f->{control}) {
        return 1 if $ctrl->{halt} || $ctrl->{terminate};
    }

    return 0;
}

sub _event_is_diagnostic {
    my ($self, $f) = @_;

    if (my $from = $f->{from_stream}) {
        return 1 if defined($from->{source}) && $from->{source} eq 'STDERR';
    }

    if (my $info = $f->{info}) {
        return 1 if first { $_->{important} || $_->{debug} } @$info;
    }

    return 0;
}

sub _send_to_run {
    my ($self, $content) = @_;
    my $target    = $self->{+_IPC_RUN}   or return;
    my $collector = $self->{+_COLLECTOR} or return;
    $collector->send_ipc($target, $content);
    return;
}

sub _send_to_harness {
    my ($self, $content) = @_;
    my $target    = $self->{+_IPC_HARNESS} or return;
    my $collector = $self->{+_COLLECTOR}   or return;
    $collector->send_ipc($target, $content);
    return;
}

sub _base_payload {
    my $self = shift;
    return (
        run_id  => $self->{+RUN_ID},
        job_id  => $self->{+JOB_ID},
        job_try => $self->{+JOB_TRY},
        stamp   => time,
    );
}

sub _emit_started {
    my $self = shift;
    return if $self->{+_EMITTED_STARTED};
    $self->{+_EMITTED_STARTED} = 1;

    $self->_send_to_run({
        kind => 'test_job_started',
        $self->_base_payload,
        collector_pid => $self->{+_COLLECTOR_PID},
        test_pid      => $self->{+_TEST_PID},
    });
}

sub _emit_diagnosing {
    my $self = shift;
    return if $self->{+_EMITTED_DIAGNOSING};
    $self->{+_EMITTED_DIAGNOSING} = 1;

    $self->_send_to_run({
        kind => 'test_job_diagnosing',
        $self->_base_payload,
    });
}

sub _emit_failing {
    my $self = shift;
    return if $self->{+_EMITTED_FAILING};
    $self->{+_EMITTED_FAILING} = 1;

    $self->_send_to_run({
        kind => 'test_job_failing',
        $self->_base_payload,
    });
}

# test_job_completed payload includes the FULL job state hash so the
# run service can accumulate per-job state in memory without reading
# disk (per F18). job_release fires alongside on the harness bus.
sub _emit_completed {
    my $self = shift;
    return if $self->{+_EMITTED_COMPLETED};
    $self->{+_EMITTED_COMPLETED} = 1;

    my $stamp = time;

    my %payload = (
        kind   => 'test_job_completed',
        run_id => $self->{+RUN_ID},
        job_id => $self->{+JOB_ID},
        job_try => $self->{+JOB_TRY},
        stamp  => $stamp,
        pass            => $self->pass ? 1 : 0,
        pass_count      => $self->pass_count,
        fail_count      => $self->fail_count,
        assertion_count => $self->{+ASSERTION_COUNT} // 0,
        exit            => $self->{+EXIT},
        plan            => $self->{+PLAN},
        halt            => $self->{+HALT},
        subtests        => $self->{+TOP_LEVEL_SUBTESTS} // [],
    );

    # Forward time accounting captured by the collector via the
    # harness_process_exit facet (audit consumed it into +EXIT).
    if (my $px = $self->{_last_exit_facet}) {
        $payload{codes}       = $px->{codes}       if $px->{codes};
        $payload{times}       = $px->{times}       if $px->{times};
        $payload{child_times} = $px->{child_times} if $px->{child_times};
        $payload{child_wall}  = $px->{child_wall}  if defined $px->{child_wall};
    }

    $self->_send_to_run(\%payload);

    $self->_send_to_harness({
        kind   => 'job_release',
        run_id => $self->{+RUN_ID},
        job_id => $self->{+JOB_ID},
        stamp  => $stamp,
    });

    return;
}

sub _audit {
    my $self = shift;
    my ($event) = @_;

    my $f  = $event->{facet_data};
    my $hf = hub_truth($f);

    my $nested = $hf->{nested} || 0;

    return $event if $hf->{buffered};

    my $is_ours = $nested == $self->{+NESTED};

    return $event unless $is_ours || $f->{from_tap};

    return $event if $f->{from_tap}    && $f->{from_tap}->{source} eq 'STDERR';
    return $event if $f->{from_stream} && $f->{from_stream}->{source} eq 'STDERR';

    return $self->_audit_subtest_start($event, $f, $nested, $is_ours)
        if $f->{harness} && $f->{harness}->{subtest_start};

    # Recovering an orphan from_tap subtest_end (no buffered subtest open)
    # rewrites $event/$f into the synthesized info-only carrier event the
    # rest of this method emits. Run before push @out so the rewritten
    # event is what gets pushed.
    ($event, $f) = $self->_audit_orphan_subtest_end_recovery($event, $f)
        if $f->{from_tap}
        && $f->{harness}->{subtest_end}
        && !($self->{+SUBTESTS} && keys %{$self->{+SUBTESTS}});

    my @out;
    push @out => $event unless $f->{harness}->{subtest_end};

    push @out => $self->_audit_close_deeper_subtests($event, $nested);

    unless ($is_ours) {
        my $st = $self->{+SUBTESTS}->{$nested} ||= {};
        my $fd = {%$f};
        push @{$st->{children}} => $fd;
        return @out;
    }

    $self->_subtest_process($f, $event);
    return @out;
}

# subtest_start arm: stash the original event under the (nested+1)
# slot so a later subtest_end can attach the children we are about
# to accumulate, suppress the original event from rendering (the
# closer carries the whole subtest), and -- only at this auditor's
# own nesting level -- emit a synthetic subtest_started announce
# event so downstream consumers can react without snooping on the
# swallowed raw event.
sub _audit_subtest_start {
    my $self = shift;
    my ($event, $f, $nested, $is_ours) = @_;

    my $st = $self->{+SUBTESTS}->{$nested + 1} ||= {};
    $st->{event} = $event;
    $f->{harness_auditor}->{no_render} = 1;
    $self->_drop_compressed_cache($event);

    # Only announce at this auditor's own nesting level -- nested
    # subtest_start events that slip past the from_tap gate above
    # are still swallowed as before. Downstream consumers that
    # watch for harness.subtest_started therefore only see the
    # top-level announcements produced by the top-level auditor.
    return unless $is_ours;

    my $announce = Test2::Harness2::Event->new(
        facet_data => {
            harness => {
                subtest_started => 1,
                nested          => $nested,
            },
            (defined $f->{trace} ? (trace => {%{$f->{trace}}}) : ()),
        },
    );
    return $announce;
}

# Synthesize a replacement event for a from_tap subtest_end that has
# no matching open subtest (TAP rendering produced a "closing brace"
# line but no buffered subtest is in progress). Suppress rendering
# of the raw closer, drop its compressed cache, and rebuild the
# event as a plain info-only carrier so the closing-brace text is
# still surfaced to the user. Returns the (possibly new) ($event,
# $f) pair the caller should use from this point on.
sub _audit_orphan_subtest_end_recovery {
    my $self = shift;
    my ($event, $f) = @_;

    $f->{harness_auditor}->{no_render} = 1;
    $self->_drop_compressed_cache($event);

    $f = {
        %{$f},
        harness_auditor => {added_by_auditor => 1},
        parent          => undef,
        trace           => undef,
        harness         => {
            %{$f->{harness} || {}},
            subtest_end => undef,
        },
        info => [
            @{$f->{info} || []},
            {
                details      => $f->{from_tap}->{details},
                tag          => $f->{from_tap}->{source} || 'STDOUT',
                from_harness => 1,
            }
        ],
    };

    $event = Test2::Harness2::Event->new(
        facet_data => $f,
    );

    return ($event, $f);
}

# Close every still-open subtest whose nesting depth is greater than
# the depth of the current event. Each closer rewrites the open
# subtest's start event into the rendered/parented form, mutates
# subtest state on $self->{+SUBTESTS}, and either nests the result
# under its own parent subtest (still deeper than ours) or hands
# the buffered children up to _subtest_process for accounting (when
# the parent is at our own nesting level). Returns the list of
# events that should appear in @out.
sub _audit_close_deeper_subtests {
    my $self = shift;
    my ($event, $nested) = @_;

    my $sts = $self->{+SUBTESTS} or return;

    my @close = sort { $b <=> $a } grep { $_ > $nested } keys %$sts;
    return unless @close;

    my @out;

    for my $n (@close) {
        my $st = delete $sts->{$n};
        my $se = $st->{event} || $event;

        my $fd = $se->{facet_data};
        delete $fd->{harness_auditor}->{no_render};
        $fd->{parent}->{hid}      ||= $n;
        $fd->{parent}->{children} ||= $st->{children};
        $fd->{harness}->{closed_by} = $event;
        $self->_drop_compressed_cache($se);

        my $pn = $n - 1;

        if ($st->{event}) {
            if ($pn > $self->{+NESTED}) {
                push @{$sts->{$pn}->{children}} => $fd;
            }
            elsif ($pn == $self->{+NESTED}) {
                $self->_subtest_process($fd, $se);
                push @out => $se;
            }
        }
        else {
            push @out => $se if $self->{+NESTED} && $pn == $self->{+NESTED};
        }
    }

    return @out;
}

sub _subtest_process {
    my $self = shift;
    my ($f, $event) = @_;

    # _subtest_process mutates $f (== $event->facet_data when an
    # event is passed) extensively below: deleting harness.closed_by,
    # toggling subtest_closed, pushing errors, etc. Drop the
    # collector's cached on-wire compressed frame so a downstream
    # zstd-aware logger recompresses against the post-audit body.
    $self->_drop_compressed_cache($event) if $event;

    my $closer = delete $f->{harness}->{closed_by};

    unless ($event) {
        $event = Test2::Harness2::Event->new(
            facet_data => $f,
        );
    }

    $self->{+NUMBERS}->{$f->{assert}->{number}}++
        if $f->{assert} && $f->{assert}->{number};

    $self->_subtest_process_parent($f, $closer)
        if $f->{parent} && $f->{assert};

    $self->_subtest_tally_facets($f);

    $self->_subtest_process_exit($f, $event)
        if $f->{harness_process_exit};

    return;
}

# Drive a buffered subtest's child facets through a fresh
# sub-auditor, collect its verdict, append the synthesized
# subtest_closed / abrupt-end error onto $f if needed, and roll the
# pass/fail outcome up onto $self's _SUB_FAILURES / FAILING_SUBTESTS
# / PASSING_SUBTESTS / FAILED_SUBTEST_TREE state. Mutates $f in
# place by appending into $f->{errors}.
sub _subtest_process_parent {
    my $self = shift;
    my ($f, $closer) = @_;

    my $name = $f->{assert}->{details} // "unnamed subtest ($f->{trace}->{frame}->[1] line $f->{trace}->{frame}->[2])";

    my $subauditor = blessed($self)->new(
        nested    => $self->{+NESTED} + 1,
        run_id    => $self->{+RUN_ID},
        job_id    => $self->{+JOB_ID},
        job_try   => $self->{+JOB_TRY},
        ipcm_info => $self->{+IPCM_INFO},
    );

    for my $sf (@{$f->{parent}->{children}}) {
        $subauditor->_subtest_process($sf);
    }

    my @errors = $subauditor->subtest_fail_error_facet_list();

    if ($f->{harness}->{subtest_start}) {
        if ($closer && $closer->{facet_data}->{harness}->{subtest_end}) {
            $f->{harness}->{subtest_closed} = 1;
        }
        elsif (!$f->{harness}->{subtest_closed}) {
            push @{$f->{errors}} => {
                tag          => 'REASON',
                fail         => 1,
                from_harness => 1,
                details      => "Buffered subtest ended abruptly (missing closing brace event)",
            };
        }
    }

    my $fail = 0;
    if (@errors) {
        push @{$f->{errors}} => @errors;
        $fail = 1;
    }
    else {
        $fail ||= $f->{assert}  && !$f->{assert}->{pass} && !($f->{amnesty} && @{$f->{amnesty}});
        $fail ||= $f->{control} && ($f->{control}->{halt} || $f->{control}->{terminate});
        $fail ||= $f->{errors}  && first { $_->{fail} } @{$f->{errors}};
    }

    if ($fail) {
        $self->{+_SUB_FAILURES}++;

        my $tree = $self->{+FAILED_SUBTEST_TREE} //= [];
        push @$tree => [$name, $subauditor->{+FAILED_SUBTEST_TREE} // []];

        push @{$self->{+FAILING_SUBTESTS} //= []} => $name;
    }
    else {
        push @{$self->{+PASSING_SUBTESTS} //= []} => $name;
    }

    # Track top-level subtests with their per-subtest counts (per F9).
    # Only the top-level auditor (NESTED == 0) records these; nested
    # sub-auditors track their own children but those are not the
    # top-level summary the run service forwards.
    if ($self->{+NESTED} == 0) {
        my $top = $self->{+TOP_LEVEL_SUBTESTS} //= [];
        push @$top => {
            name       => $name,
            pass       => $fail ? 0 : 1,
            count_pass => $subauditor->pass_count,
            count_fail => $subauditor->fail_count,
        };
    }

    return;
}

# Update assertion / failure / error / plan tallies on $self based
# on the facets in $f. Pure bookkeeping -- no event mutation, no
# downstream emission.
sub _subtest_tally_facets {
    my $self = shift;
    my ($f) = @_;

    $self->{+ASSERTION_COUNT}++ if $f->{assert};

    if ($f->{assert} && !$f->{assert}->{pass} && !($f->{amnesty} && @{$f->{amnesty}})) {
        $self->{+_FAILURES}++;
    }

    if ($f->{control} || $f->{errors}) {
        my $err = $f->{control} && ($f->{control}->{halt} || $f->{control}->{terminate});
        $err ||= $f->{errors} && first { $_->{fail} } @{$f->{errors}};
        $self->{+_ERRORS}++ if $err;
        $self->{+HALT} = $f->{control}->{details} || '1'
            if $f->{control} && $f->{control}->{halt} && (!$self->{+HALT} || $self->{+HALT} eq '1');
    }

    if ($f->{plan} && !$f->{plan}->{none}) {
        $self->{+_PLANS}++;
        $self->{+PLAN} = $f->{plan};
    }

    return;
}

# harness_process_exit arm of _subtest_process: stash the exit code
# on $self->{+EXIT}, synthesize the harness_job_exit facet on $f,
# and append every reason in fail_error_facet_list onto $f->{errors}
# so the downstream consumer sees a single event carrying both the
# exit code and the auditor's verdict on it.
sub _subtest_process_exit {
    my $self = shift;
    my ($f, $event) = @_;

    my $px = $f->{harness_process_exit};
    $self->{+EXIT} = $px->{all};

    # Cache the exit facet for the test_job_completed payload (time
    # accounting fields). The auditor sees harness_process_exit
    # exactly once, so this is a one-shot capture.
    $self->{_last_exit_facet} = {
        codes       => $px,
        (defined $px->{times}       ? (times       => $px->{times})       : ()),
        (defined $px->{child_times} ? (child_times => $px->{child_times}) : ()),
        (defined $px->{child_wall}  ? (child_wall  => $px->{child_wall})  : ()),
    };

    # The harness_job_exit facet keeps its own stamp -- this is a payload
    # field on the facet, not the event-wide stamp mirror that lives in
    # trace.stamp. Prefer trace.stamp from the event we are processing,
    # and fall back to the wall clock if the event was synthesized
    # without a trace facet.
    my $jx_stamp = ($f->{trace} && $f->{trace}->{stamp}) // time;

    $f->{harness_job_exit} //= {
        job_id  => $self->{+JOB_ID},
        job_try => $self->{+JOB_TRY},
        exit    => $px->{all},
        codes   => $px,
        stamp   => $jx_stamp,
        (defined $px->{times}       ? (times       => $px->{times})       : ()),
        (defined $px->{child_times} ? (child_times => $px->{child_times}) : ()),
        (defined $px->{child_wall}  ? (child_wall  => $px->{child_wall})  : ()),
    };

    push @{$f->{errors}} => $self->fail_error_facet_list;
    return;
}

sub subtest_fail_error_facet_list {
    my $self = shift;

    my @out;

    my $plan  = $self->{+PLAN} ? $self->{+PLAN}->{count} : undef;
    my $count = $self->{+ASSERTION_COUNT};

    my $numbers = $self->{+NUMBERS};
    my $max     = max(keys %$numbers);
    if ($max) {
        for my $i (1 .. $max) {
            if (!$numbers->{$i}) {
                push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Assertion number $i was never seen"};
            }
            elsif ($numbers->{$i} > 1) {
                push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Assertion number $i was seen more than once"};
            }
        }
    }

    if (!$self->{+_PLANS}) {
        if ($count) {
            push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "No plan was declared"};
        }
        else {
            push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "No plan was declared, and no assertions were made."};
        }
    }
    elsif ($self->{+_PLANS} > 1) {
        push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Too many plans were declared (Count: $self->{+_PLANS})"};
    }

    push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Planned for $plan assertions, but saw $count"}
        if $plan && $count != $plan;

    push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Subtest failures were encountered (Count: $self->{+_SUB_FAILURES})"}
        if $self->{+_SUB_FAILURES};

    return @out;
}

sub fail_error_facet_list {
    my $self = shift;

    my @out;

    my $incomplete_subtests = values %{$self->{+SUBTESTS}};
    push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "One or more incomplete subtests (Count: $incomplete_subtests)"}
        if $incomplete_subtests;

    if (defined(my $wstat = $self->{+EXIT})) {
        if ($wstat == -1) {
            push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "The harness could not get the exit code! (Code: $wstat)"};
        }
        elsif ($wstat) {
            my $e = parse_exit($wstat);
            push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Test script returned error (Err: $e->{err})"}
                if $e->{err};
            push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Test script returned error (Signal: $e->{sig})"}
                if $e->{sig};
        }
    }

    push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Errors were encountered (Count: $self->{+_ERRORS})"}
        if $self->{+_ERRORS};

    push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Assertion failures were encountered (Count: $self->{+_FAILURES})"}
        if $self->{+_FAILURES};

    push @out => $self->subtest_fail_error_facet_list();

    return @out;
}

# Drop the collector's cached on-wire compressed JSON frame and the
# matching as_json cache from $event. Auditors call this immediately
# before mutating the event body so a downstream zstd-aware logger
# does not write stale bytes that no longer match the post-audit
# event. Tolerates plain hashref events (used by the unit tests) as
# well as blessed Test2::Harness2::Event instances since both are
# hashes underneath.
sub _drop_compressed_cache {
    my ($self, $event) = @_;
    return unless $event;
    delete $event->{compressed_form};
    delete $event->{json};
    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Auditor::Test - Auditor that determines pass/fail
of a single test execution.

=head1 DESCRIPTION

This auditor consumes events one at a time from a
L<Test2::Harness2::Collector> and decides whether the test process is passing
or failing. It tracks assertions, plans, subtests (including deep nesting),
errors, halts/bail-outs, and the process exit code, and verifies the resulting
state is internally consistent (plan matches assertion count, no duplicate or
missing assertion numbers, no abandoned subtests, etc.).

It implements the L<Test2::Harness2::Role::Auditor> contract: each call to
L</audit_event> returns zero or more events for downstream consumers, and the
auditor may emit additional synthesized events (for example to surface
mismatched assertion counts or buffered-subtest-end recovery).

=head2 Absorbed L<TestObserver> duties

Post-C<new_log_refactor> M2 step 4+5, this auditor also handles the
upward-facing IPC duties that used to live in
C<Test2::Harness2::Collector::Observer::TestObserver>:

=over 4

=item C<test_job_started>

Emitted from C<startup($collector)> once the test process has been
launched.

=item C<test_job_diagnosing>

Emitted from C<audit_event> on the first diagnostic facet
(important / debug info, or a STDERR-sourced parser facet).

=item C<test_job_failing>

Emitted from C<audit_event> on the first failing assertion or
error-without-amnesty.

=item C<test_job_completed>

Emitted from C<shutdown($collector)>; carries the auditor's final
state hash (per amendment F18).

=item C<job_release>

Emitted from C<shutdown> alongside C<test_job_completed>.

=back

All emissions go through the collector's IPC client; the auditor
never holds its own bus connection.

=head2 Top-level subtests tracking

The auditor also tracks the set of top-level subtests it observed
along with their pass/fail state. This is what the run service's
C<collector_report> facet (per F17) aggregates across jobs to
describe per-test subtest state in the run-level summary.

=head1 SYNOPSIS

    use Test2::Harness2::Collector::Auditor::Test;

    my $auditor = Test2::Harness2::Collector::Auditor::Test->new();

    for my $event (@events) {
        my @forward = $auditor->audit_event($event);
        # forward to loggers...
    }

    print "Pass!\n" if $auditor->pass;
    print "Fail!\n" if $auditor->fail;

=head1 METHODS

=over 4

=item @events = $auditor->audit_event($event)

Process a single event, updating internal state, and return zero or more
events for downstream consumers (loggers, renderers, ...). The returned list
may include the original event, a transformed copy, or additional events
synthesized by the auditor (such as recovery from a stray subtest_end).

=item $int = $auditor->assertion_count()

Number of assertions that have been seen.

=item $int = $auditor->exit()

If the test process has exited and a C<harness_process_exit> facet has been
seen, this returns the raw wait-status integer. Returns C<undef> otherwise.

=item $bool = $auditor->fail()

True if the test is failing.

=item $bool = $auditor->pass()

True if the test is passing.

=item $bool = $auditor->passing()

Alias for L</pass>, satisfying L<Test2::Harness2::Role::Auditor>.

=item $bool = $auditor->failing()

Alias for L</fail>, satisfying L<Test2::Harness2::Role::Auditor>.

=item $n = $auditor->fail_count()

Number of distinct failures seen (assertion failures, errors, failed subtests,
plus halts and non-zero exits).

=item $n = $auditor->pass_count()

Number of passing assertions seen.

=item $bool = $auditor->has_exit()

True once an exit facet has been observed.

=item $bool = $auditor->has_plan()

True once a non-skip plan has been observed.

=item $string = $auditor->halt()

If the test was halted via a bail-out, the human-readable reason. C<undef>
otherwise.

=item $hash = $auditor->numbers()

Internal map of TAP assertion numbers to their occurrence counts. Only
populated for tests that produce TAP.

=item $plan = $auditor->plan()

The plan facet, once seen.

=item $tree = $auditor->failed_subtest_tree()

Nested arrayref describing the path through any failed subtests, suitable for
producing diagnostic summaries.

=item $int = $auditor->nested()

Nesting depth this auditor represents. C<0> for the top-level test, greater
than zero for sub-auditors created to validate nested subtests.

=item @facets = $auditor->fail_error_facet_list()

Internal: a list of error facet hashes describing every reason the test is
failing. Appended to the C<harness_process_exit> event when it is observed.

=item @facets = $auditor->subtest_fail_error_facet_list()

Internal: a list of error facet hashes describing the failures attributable
to a single subtest's contents (plan / assertion-count / number / nested
subtest-failure issues), used recursively for nested subtests.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
