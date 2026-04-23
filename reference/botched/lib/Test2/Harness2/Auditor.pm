package Test2::Harness2::Auditor;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak confess/;
use List::Util qw/first max/;
use Time::HiRes qw/time/;

use Test2::Harness2::Util qw/hub_truth parse_exit/;
use Test2::Harness2::Event;

use Test2::Harness2::Util::HashBase qw{
    -assertion_count
    -plan
    -exit
    -halt
    -nested
    -_errors
    -_failures
    -_sub_failures
    -_plans
    -numbers
    -subtests
};

sub init {
    my $self = shift;

    $self->{+ASSERTION_COUNT} = 0;
    $self->{+_FAILURES}       = 0;
    $self->{+_ERRORS}         = 0;
    $self->{+_SUB_FAILURES}   = 0;
    $self->{+_PLANS}          = 0;
    $self->{+NUMBERS}         = {};
    $self->{+SUBTESTS}        = {};
    $self->{+NESTED}          = 0 unless defined $self->{+NESTED};
}

sub pass { !$_[0]->fail }

sub fail {
    my $self = shift;
    return 1 if $self->{+_ERRORS} > 0;
    return 1 if $self->{+_FAILURES} > 0;
    return 1 if $self->{+_SUB_FAILURES} > 0;
    return 1 if $self->{+HALT};

    if (defined $self->{+EXIT}) {
        if ($self->{+EXIT} == -1) {
            return 1;
        }
        else {
            my $e = parse_exit($self->{+EXIT});
            return 1 if $e->{err} || $e->{sig};
        }
    }

    # Plan violations (only check if we've seen an exit or halt, i.e. test is done)
    my $done = defined($self->{+EXIT}) || defined($self->{+HALT});
    if ($done) {
        my @plan_errors = $self->_plan_error_facets();
        return 1 if @plan_errors;
    }

    return 0;
}

sub has_exit { defined $_[0]->{+EXIT} }
sub has_plan { defined $_[0]->{+PLAN} }

sub audit {
    my $self   = shift;
    my @events = @_;

    my @out;
    for my $event (@events) {
        $self->_audit($event);
        push @out => $event;
    }

    push @out => $self->_finalize();

    return @out;
}

sub _audit {
    my $self = shift;
    my ($event) = @_;

    my $f  = $event->{facet_data};
    my $hf = hub_truth($f);

    my $nested = $hf->{nested} || 0;

    # Only process events at our nesting level (or from_tap events)
    my $is_ours = ($nested == $self->{+NESTED});
    return unless $is_ours || $f->{from_tap};

    # Skip STDERR events
    return if $f->{from_tap}    && $f->{from_tap}->{source}    && $f->{from_tap}->{source} eq 'STDERR';
    return if $f->{from_stream} && $f->{from_stream}->{source} && $f->{from_stream}->{source} eq 'STDERR';

    # Handle assert facet
    if ($f->{assert}) {
        $self->{+ASSERTION_COUNT}++;

        # Track assertion numbers
        if (my $num = $f->{assert}->{number}) {
            $self->{+NUMBERS}->{$num}++;
        }

        # A failing assertion that is NOT covered by amnesty/TODO is a real failure
        if (!$f->{assert}->{pass} && !($f->{amnesty} && @{$f->{amnesty}})) {
            $self->{+_FAILURES}++;
        }
    }

    # Handle plan facet
    if ($f->{plan} && !$f->{plan}->{none}) {
        $self->{+_PLANS}++;
        $self->{+PLAN} = $f->{plan};
    }

    # Handle control facet (bail out / halt)
    if ($f->{control}) {
        if ($f->{control}->{halt} || $f->{control}->{terminate}) {
            $self->{+_ERRORS}++;
            if ($f->{control}->{halt} && (!$self->{+HALT} || $self->{+HALT} eq '1')) {
                $self->{+HALT} = $f->{control}->{details} || '1';
            }
        }
    }

    # Handle error facets
    if ($f->{errors}) {
        my $has_fail = first { $_->{fail} } @{$f->{errors}};
        $self->{+_ERRORS}++ if $has_fail;
    }

    # Handle job exit
    if ($f->{harness_job_exit}) {
        $self->{+EXIT} = $f->{harness_job_exit}->{exit};
    }

    # Handle parent (subtest)
    if ($f->{parent} && $f->{assert}) {
        $self->_process_subtest($f, $event);
    }

    return;
}

sub _process_subtest {
    my $self = shift;
    my ($f, $event) = @_;

    my $subauditor = ref($self)->new(nested => $self->{+NESTED} + 1);

    # Process all child events through the subauditor
    for my $child_f (@{$f->{parent}->{children} // []}) {
        my $child_event = Test2::Harness2::Event->new(
            facet_data => $child_f,
            job_id     => $event->job_id // 0,
            job_try    => $event->job_try,
            defined($event->run_id) ? (run_id => $event->run_id) : (),
        );
        $subauditor->_audit($child_event);
    }

    # Get errors from the subauditor
    my @errors = $subauditor->_subtest_error_facets();

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
    }

    return;
}

sub _plan_error_facets {
    my $self = shift;

    my @out;

    my $plan  = $self->{+PLAN} ? $self->{+PLAN}->{count} : undef;
    my $count = $self->{+ASSERTION_COUNT};

    # Check for gaps/duplicates in assertion numbers
    my $numbers = $self->{+NUMBERS};
    if (%$numbers) {
        my $max = max(keys %$numbers);
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
    }

    if (!$self->{+_PLANS}) {
        if ($count) {
            push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "No plan was declared"};
        }
        # No plan AND no assertions — empty test is OK, no error
    }
    elsif ($self->{+_PLANS} > 1) {
        push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Too many plans were declared (Count: $self->{+_PLANS})"};
    }

    # Plan count mismatch (skip_all has count=0, that's fine)
    push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Planned for $plan assertions, but saw $count"}
        if defined($plan) && $plan > 0 && $count != $plan;

    push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Subtest failures were encountered (Count: $self->{+_SUB_FAILURES})"}
        if $self->{+_SUB_FAILURES};

    return @out;
}

sub _subtest_error_facets {
    my $self = shift;
    return $self->_plan_error_facets();
}

sub _finalize {
    my $self = shift;

    my @error_facets;

    # Incomplete subtests
    my $incomplete = scalar keys %{$self->{+SUBTESTS} // {}};
    if ($incomplete) {
        push @error_facets => {tag => 'REASON', fail => 1, from_harness => 1, details => "One or more incomplete subtests (Count: $incomplete)"};
    }

    # Non-zero exit
    if (defined $self->{+EXIT}) {
        if ($self->{+EXIT} == -1) {
            push @error_facets => {tag => 'REASON', fail => 1, from_harness => 1, details => "The harness could not get the exit code! (Code: $self->{+EXIT})"};
        }
        else {
            my $e = parse_exit($self->{+EXIT});
            if ($e->{err}) {
                push @error_facets => {tag => 'REASON', fail => 1, from_harness => 1, details => "Test script returned error (Err: $e->{err})"};
            }
            if ($e->{sig}) {
                push @error_facets => {tag => 'REASON', fail => 1, from_harness => 1, details => "Test script returned error (Signal: $e->{sig})"};
            }
        }
    }

    # Explicit error counter
    if ($self->{+_ERRORS}) {
        push @error_facets => {tag => 'REASON', fail => 1, from_harness => 1, details => "Errors were encountered (Count: $self->{+_ERRORS})"};
    }

    # Assertion failures
    if ($self->{+_FAILURES}) {
        push @error_facets => {tag => 'REASON', fail => 1, from_harness => 1, details => "Assertion failures were encountered (Count: $self->{+_FAILURES})"};
    }

    # Plan errors
    push @error_facets => $self->_plan_error_facets();

    return unless @error_facets;

    # Build a single error event containing all error facets
    my $event = Test2::Harness2::Event->new(
        facet_data => {
            errors          => \@error_facets,
            harness_auditor => {added_by_auditor => 1},
            harness         => {},
        },
    );

    return $event;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Auditor - Determines pass/fail for a test execution by processing events.

=head1 DESCRIPTION

The Auditor processes events as they arrive, tracks state, and determines pass/fail
for a test run. It may also generate new events (e.g., error events for plan violations).

Events flow through the Auditor, then the output includes both original AND
auditor-generated events that get fed to renderers.

=head1 SYNOPSIS

    use Test2::Harness2::Auditor;

    my $auditor = Test2::Harness2::Auditor->new();

    my @all_events = $auditor->audit(@events);

    print "Pass!" if $auditor->pass;
    print "Fail!" if $auditor->fail;

=head1 METHODS

=over 4

=item @all_events = $auditor->audit(@events)

Process a list of events. Returns all original events plus any auditor-generated
error events (from plan violations, bad exit code, etc.).

=item $bool = $auditor->pass

Returns true if the test is currently passing.

=item $bool = $auditor->fail

Returns true if the test is currently failing.

=item $bool = $auditor->has_exit

Returns true if an exit event has been seen.

=item $bool = $auditor->has_plan

Returns true if a plan event has been seen.

=item $int = $auditor->assertion_count

Number of assertions seen so far.

=item $plan = $auditor->plan

The plan facet if one has been seen, otherwise undef.

=item $exit = $auditor->exit

The exit value from the harness_job_exit event, or undef if not yet seen.

=item $reason = $auditor->halt

The bail-out reason if a halt was seen, otherwise undef.

=item $int = $auditor->nested

Nesting level — 0 for the top-level test, > 0 for subtests.

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

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
