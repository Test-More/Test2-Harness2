package App::Yath2::Filter;
use strict;
use warnings;

our $VERSION = '2.000012';

use Carp qw/croak/;

sub new {
    my $class = shift;
    bless {}, $class;
}

# Returns $event to pass it downstream, undef to drop it.
# Subclasses must override this method.
sub filter_event { croak "$_[0] forgot to override 'filter_event()'" }

1;

__END__

=head1 NAME

App::Yath2::Filter - Base class for output pipeline event filters

=head1 DESCRIPTION

A filter sits between the L<App::Yath2::OutputManager> and a renderer.
For each event the manager dispatches, it calls C<filter_event> on every
filter in the renderer's chain in sequence. A filter returns the event
(possibly transformed) to pass it downstream, or C<undef> to drop it.

Filters are stateless or near-stateless. Stateful buffering (e.g. holding
all of a job's events and flushing only on failure) belongs upstream in
the artifact-reading layer, not here.

=head1 INTERFACE

=over 4

=item $event_or_undef = $filter->filter_event($event)

Inspect C<$event> and return it (or a transformed copy) to let it through,
or return C<undef> to drop it for this pipeline. When a filter returns
C<undef> the manager stops processing that event for the current renderer
immediately — later filters in the chain are not called.

=back

=cut
