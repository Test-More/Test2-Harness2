package Test2::Tools::HarnessTester;
use strict;
use warnings;

our $VERSION = '2.000000';

use App::Yath2::Tester qw/make_example_dir/;

use Importer Importer => qw/import/;
our @EXPORT_OK = qw/make_example_dir summarize_events/;

sub summarize_events {
    my ($events) = @_;

    require Test2::Collector::Auditor;
    require Test2::Collector::Event;

    my $auditor = Test2::Collector::Auditor->new;

    for my $e (@$events) {
        my $ev = Test2::Collector::Event->new(facet_data => $e->facet_data);
        $auditor->process_event($ev);
    }

    my $state = $auditor->final_state;

    return {
        plan       => $state->{plan},
        pass       => $state->{pass} ? 1 : 0,
        fail       => $state->{pass} ? 0 : 1,
        errors     => $state->{errors},
        failures   => $state->{failures},
        assertions => $state->{assertion_count},
    };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Tools::HarnessTester - Run events through a harness for a summary

=head1 DESCRIPTION

This tool allows you to process events through the L<Test2::Collector::Auditor>.
The main benefit here is to get a pass/fail result, as well as counts for
assertions, failures, and errors.

=head1 SYNOPSIS

    use Test2::V0;
    use Test2::API qw/intercept/;
    use Test2::Tools::HarnessTester qw/summarize_events/;

    my $events = intercept {
        ok(1, "pass");
        ok(2, "pass gain");
        done_testing;
    };

    is(
        summarize_events($events),
        {
            # Each of these is the negation of the other, no need to check both
            pass       => 1,
            fail       => 0,

            # The plan facet, see Test2::EventFacet::Plan
            plan       => {count => 2},

            # Statistics
            assertions => 2,
            errors     => 0,
            failures   => 0,
        }
    );

=head1 EXPORTS

=head2 $summary = summarize_events($events)

This takes an arrayref of events, such as that produced by C<intercept {...}>
from L<Test2::API>. The result is a hashref that summarizes the results of the
events as processed by L<Test2::Collector::Auditor>.

Fields in the summary hash:

=over 4

=item pass => $BOOL

=item fail => $BOOL

These are negatives of eachother. These represent the pass/fail state after
processing the events. When one is true the other should be false. These are
normalized to C<1> and C<0>.

=item plan => $HASHREF

If a plan was provided this will have the L<Test2::EventFacet::Plan> facet, but
as a hashref, not a blessed instance.

B<Note:> This is reference to the original data, not a copy, if you modify it
you will modify the event as well.

=item assertions => $INT

Count of assertions made.

=item errors => $INT

Count of errors seen.

=item failures => $INT

Count of failures seen.

=back

=head2 $path = make_example_dir()

This will create a temporary directory with 't', 't2', and 'xt' subdirectories
each of which will contain a single passing test.

This is re-exported from L<App::Yath2::Tester>.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness2/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
