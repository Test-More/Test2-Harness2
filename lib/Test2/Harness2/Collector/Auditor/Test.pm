package Test2::Harness2::Collector::Auditor::Test;
use strict;
use warnings;

our $VERSION = '2.000000';

use Scalar::Util qw/blessed/;
use List::Util qw/first max/;

use Test2::Harness2::Util qw/hub_truth/;
use Test2::Harness2::Util::IPC qw/parse_exit/;
use Test2::Harness2::Event;

use Object::HashBase qw{
    recorder
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

    +_state
    +_state_failing
    +_state_diagnosing
};

use Role::Tiny::With;
with 'Test2::Harness2::Collector::Role::Auditor';

sub init {
    my $self = shift;

    $self->{+_FAILURES}       = 0;
    $self->{+_ERRORS}         = 0;
    $self->{+_SUB_FAILURES}   = 0;
    $self->{+_PLANS}          = 0;
    $self->{+ASSERTION_COUNT} = 0;

    $self->{+NUMBERS}            = {};
    $self->{+SUBTESTS}           = {};
    $self->{+PASSING_SUBTESTS}   = [];
    $self->{+FAILING_SUBTESTS}   = [];
    $self->{+TOP_LEVEL_SUBTESTS} = [];

    $self->{+NESTED} //= 0;
    $self->{+_STATE} = 'starting';
}

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

sub startup {
    my $self = shift;
    $self->_transition_state('starting') if $self->{+NESTED} == 0;
    return;
}

sub shutdown {
    my $self = shift;
    $self->_transition_state('completed') if $self->{+NESTED} == 0;
    return;
}

sub audit_event {
    my $self = shift;
    my ($event) = @_;

    $event->{facet_data} //= {};
    my $f = $event->{facet_data};

    if (!$self->{+_STATE_FAILING} && $self->_event_is_failing($f)) {
        $self->{+_STATE_FAILING} = 1;
        $self->_transition_state('failing');
    }
    if (!$self->{+_STATE_DIAGNOSING} && $self->_event_is_diagnostic($f)) {
        $self->{+_STATE_DIAGNOSING} = 1;
        $self->_transition_state('diagnosing');
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

sub _transition_state {
    my ($self, $state) = @_;
    return unless $self->{+RECORDER};
    $self->{+RECORDER}->record_state($state, undef);
    $self->{+_STATE} = $state;
    return;
}

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

sub _audit_subtest_start {
    my $self = shift;
    my ($event, $f, $nested, $is_ours) = @_;

    my $st = $self->{+SUBTESTS}->{$nested + 1} ||= {};
    $st->{event} = $event;
    $f->{harness_auditor}->{no_render} = 1;
    $self->_drop_compressed_cache($event);

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

    $event = Test2::Harness2::Event->new(facet_data => $f);

    return ($event, $f);
}

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

    $self->_drop_compressed_cache($event) if $event;

    my $closer = delete $f->{harness}->{closed_by};

    $event //= Test2::Harness2::Event->new(facet_data => $f);

    $self->{+NUMBERS}->{$f->{assert}->{number}}++
        if $f->{assert} && $f->{assert}->{number};

    $self->_subtest_process_parent($f, $closer)
        if $f->{parent} && $f->{assert};

    $self->_subtest_tally_facets($f);

    $self->_subtest_process_exit($f, $event)
        if $f->{harness_process_exit};

    return;
}

sub _subtest_process_parent {
    my $self = shift;
    my ($f, $closer) = @_;

    my $name = $f->{assert}->{details}
        // "unnamed subtest ($f->{trace}->{frame}->[1] line $f->{trace}->{frame}->[2])";

    my $subauditor = blessed($self)->new(nested => $self->{+NESTED} + 1);

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

sub _subtest_process_exit {
    my $self = shift;
    my ($f, $event) = @_;

    my $px = $f->{harness_process_exit};
    $self->{+EXIT} = $px->{all};

    my $jx_stamp = ($f->{trace} && $f->{trace}->{stamp}) // time;

    $f->{harness_job_exit} //= {
        exit  => $px->{all},
        codes => $px,
        stamp => $jx_stamp,
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

sub _drop_compressed_cache {
    my ($self, $event) = @_;
    return unless $event;
    delete $event->{compressed_form};
    delete $event->{_json};
    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Auditor::Test - Auditor that decides pass/fail
of a single test execution.

=head1 DESCRIPTION

Consumes one L<Test2::Harness2::Event> at a time via L</audit_event>; tracks
assertions, plans, nested subtests (recursively), errors, halts/bail-outs,
and the process exit code; and emits synthetic events for subtest
announcements and recovery from malformed TAP. Returns zero or more events
per call for the recorder to write.

State transitions (C<starting>, C<diagnosing>, C<failing>, C<completed>) are
mirrored through the C<recorder> attribute when set: the auditor calls
C<record_state> on the recorder once per unique state encountered. When no
recorder is configured the auditor still tracks state internally but emits
nothing.

=head1 SYNOPSIS

    use Test2::Harness2::Collector::Auditor::Test;
    use Test2::Harness2::Collector::Recorder::Files;

    my $r = Test2::Harness2::Collector::Recorder::Files->new(dir => $path);
    my $a = Test2::Harness2::Collector::Auditor::Test->new(recorder => $r);

    $a->startup;
    for my $event (@events) {
        my @forward = $a->audit_event($event);
        $r->record_event($_) for @forward;
    }
    $a->shutdown;

    print "Pass!\n" if $a->pass;

=head1 ATTRIBUTES

=over 4

=item recorder

Optional. When set, the auditor calls C<record_state> on this object once per
state transition. Must implement L<Test2::Harness2::Collector::Role::Recorder>.

=item nested

Subtest nesting depth this auditor represents. C<0> for the top-level test;
nested subauditors are spawned automatically by C<_subtest_process_parent>.

=back

=head1 PUBLIC METHODS

=over 4

=item @events = $auditor->audit_event($event)

Process one event, update internal state, and return zero or more events
for downstream consumers. The returned list may carry the original event,
a transformed copy, or freshly synthesized events (subtest_started
announcements, orphan subtest_end recovery, etc.).

=item $auditor->startup

Lifecycle hook the collector calls before the first event. Emits the
C<starting> state to the recorder when one is configured and this is the
top-level auditor.

=item $auditor->shutdown

Lifecycle hook the collector calls after the collected process exits.
Emits the C<completed> state to the recorder when one is configured and
this is the top-level auditor.

=item $bool = $auditor->pass

True when no failure has been registered.

=item $bool = $auditor->fail

True when at least one failure has been registered.

=item $bool = $auditor->passing

Alias for L</pass> (satisfies L<Test2::Harness2::Collector::Role::Auditor>).

=item $bool = $auditor->failing

Alias for L</fail> (satisfies L<Test2::Harness2::Collector::Role::Auditor>).

=item $n = $auditor->fail_count

Total count of distinct failures: failing assertions, errors, failed
subtests, halts, and non-zero exits.

=item $n = $auditor->pass_count

Count of passing assertions.

=item $int = $auditor->assertion_count

Total assertions observed (pass + fail).

=item $int = $auditor->exit

Raw wait-status of the collected process once a C<harness_process_exit>
facet has been observed, C<undef> until then.

=item $bool = $auditor->has_exit

True once an exit facet has been seen.

=item $bool = $auditor->has_plan

True once a non-skip plan has been seen.

=item $string = $auditor->halt

Bail-out reason when the run was halted, C<undef> otherwise.

=item $plan = $auditor->plan

The plan facet hashref, once observed.

=item $hashref = $auditor->final_state

Snapshot of the auditor's verdict: C<pass>, C<fail_count>, C<pass_count>,
C<assertion_count>, C<exit>, C<plan>, C<halt>, and the top-level subtest
summary.

=item @facets = $auditor->fail_error_facet_list

List of error facet hashes describing every reason the run is failing.
Attached to the C<harness_process_exit> event when it is observed.

=item @facets = $auditor->subtest_fail_error_facet_list

Subset of L</fail_error_facet_list> covering only failures that belong
to a single subtest's contents (plan / count / numbering / nested
subtest-failure issues). Used recursively for nested subtests.

=back

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

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
