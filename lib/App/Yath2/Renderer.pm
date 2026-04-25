package App::Yath2::Renderer;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;

use Object::HashBase qw{
    <settings
};

sub init { }

# Return an ordered list of filter class names (or pre-built filter instances)
# that the OutputManager should chain before handing events to this renderer.
# The default is no filters. Subclasses override this to declare their
# desired log-level or content-selection filters based on settings.
sub desired_filters { () }

sub render_event { croak "$_[0] forgot to override 'render_event()'" }

sub is_async { 0 }

sub start         { }
sub step          { }
sub signal        { }
sub finish        { }
sub exit_hook     { }
sub end_of_events { }
sub weight        { 0 }

1;

__END__

=head1 NAME

App::Yath2::Renderer - Base class for output renderers

=head1 DESCRIPTION

A renderer receives a pre-filtered event stream from the
L<App::Yath2::OutputManager> and is responsible only for B<formatting>
that stream and B<writing> it to a destination (STDOUT, a file, a
database, etc.).

Renderers must not make filtering decisions themselves. Filtering is the
job of L<App::Yath2::Filter> subclasses declared via C<desired_filters>.

=head1 INTERFACE

=over 4

=item @filter_specs = $renderer->desired_filters

Return an ordered list of filter class names or pre-built filter instances
that the C<OutputManager> should chain before this renderer. Called once
by C<add_renderer> at registration time.

The default implementation returns an empty list (no filtering). Subclasses
override this to select filters based on their C<settings> (log level,
verbosity, etc.).

    sub desired_filters {
        my $self = shift;
        my $level = $self->{+SETTINGS}{log_level} // 'default';
        return ('App::Yath2::Filter::Quiet')   if $level eq 'quiet';
        return ('App::Yath2::Filter::Verbose')  if $level eq 'verbose';
        return ();
    }

=item $renderer->render_event($event)

Receive one event and produce output. Must be overridden by subclasses.

=item $renderer->start

Called by the C<OutputManager> before the first event is dispatched.

=item $renderer->finish

Called by the C<OutputManager> after the last event has been dispatched.

=item $renderer->signal($sig)

Called when the process receives a signal (e.g. TERM).

=item $renderer->end_of_events

Called after C<finish> to notify the renderer that no further events will
arrive. Async renderers may use this to drain internal queues.

=item $bool = $renderer->is_async

Return true if this renderer runs asynchronously (e.g. in a forked child).
Default: 0.

=back

=cut
