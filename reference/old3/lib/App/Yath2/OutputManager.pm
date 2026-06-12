package App::Yath2::OutputManager;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use Test2::Harness2::Util qw/load_module/;

use Object::HashBase qw{
    <pipelines
};

sub init {
    my $self = shift;
    $self->{+PIPELINES} //= [];
}

# Register a renderer.  Calls desired_filters() to build its filter chain,
# then either attaches it to an existing pipeline whose chain is identical
# (sharing a single chain run across multiple renderers) or creates a new
# pipeline for it.  Calls start() on the renderer immediately.
#
# Pipelines are only shared when every filter spec is a plain class name
# string.  Pre-built filter instances carry opaque state; they always get
# their own pipeline even if they happen to share a class with another.
sub add_renderer {
    my ($self, $renderer) = @_;

    croak "renderer must define render_event"
        unless $renderer->can('render_event');

    my @specs = $renderer->desired_filters;

    my @filters;
    my @key_parts;
    for my $spec (@specs) {
        if (ref $spec) {
            push @filters   => $spec;
            push @key_parts => "$spec";  # unique per instance — never shares with another
        }
        else {
            load_module($spec);
            push @filters   => $spec->new;
            push @key_parts => $spec;
        }
    }
    my $key = join "\0" => @key_parts;

    for my $pipeline (@{$self->{+PIPELINES}}) {
        if ($pipeline->{key} eq $key) {
            push @{$pipeline->{renderers}} => $renderer;
            $renderer->start;
            return;
        }
    }

    push @{$self->{+PIPELINES}} => {
        key       => $key,
        filters   => \@filters,
        renderers => [$renderer],
    };
    $renderer->start;
    return;
}

sub dispatch {
    my ($self, $event) = @_;

    for my $pipeline (@{$self->{+PIPELINES}}) {
        my $ev = $event;
        for my $f (@{$pipeline->{filters}}) {
            $ev = $f->filter_event($ev);
            last unless defined $ev;
        }
        next unless defined $ev;
        $_->render_event($ev) for @{$pipeline->{renderers}};
    }

    return;
}

sub _all_renderers {
    my $self = shift;
    return map { @{$_->{renderers}} } @{$self->{+PIPELINES}};
}

# finish() may be called explicitly for deterministic teardown, or it fires
# automatically when the OutputManager goes out of scope via DESTROY.
# The guard ensures renderers are never finished twice.
sub finish {
    my $self = shift;
    return if $self->{_finished}++;
    $_->finish for $self->_all_renderers;
    return;
}

sub DESTROY { $_[0]->finish }

sub signal {
    my ($self, $sig) = @_;
    $_->signal($sig) for $self->_all_renderers;
    return;
}

sub end_of_events {
    my $self = shift;
    $_->end_of_events for $self->_all_renderers;
    return;
}

1;

__END__

=head1 NAME

App::Yath2::OutputManager - Manage output pipelines (filter chains + renderers)

=head1 SYNOPSIS

    use App::Yath2::OutputManager;
    use App::Yath2::Renderer::Default;

    my $om = App::Yath2::OutputManager->new;
    $om->add_renderer(App::Yath2::Renderer::Default->new(settings => $settings));

    $om->dispatch($event) for @events;
    # finish() fires automatically when $om goes out of scope,
    # or call it explicitly for early deterministic teardown.

=head1 DESCRIPTION

C<App::Yath2::OutputManager> sits between the event source and one or more
renderers. It manages an ordered set of B<pipelines>, where each pipeline
is a shared filter chain followed by one or more renderers.

=head2 Pipelines

When C<add_renderer> is called the manager asks the renderer for its
desired filter chain via C<< $renderer->desired_filters >>. Each element
of the returned list is either a filter class name (loaded and instantiated
automatically) or a pre-built filter instance.

A pipeline key is derived from the spec list: class-name strings contribute
their name; pre-built instances contribute their stringified address
(C<"$obj">). If an existing pipeline has an identical key the renderer is
attached to it, so the filter chain runs only once per dispatched event
regardless of how many renderers share it. Two separately constructed
instances of the same class produce distinct keys and therefore distinct
pipelines, which is the correct behaviour since they carry independent
state.

=head2 Lifecycle

C<< $renderer->start >> is called immediately when the renderer is
registered via C<add_renderer>.

C<< $renderer->finish >> is called for all renderers when the
C<OutputManager> is destroyed or when C<finish> is called explicitly.
Explicit and implicit teardown are guarded against double-firing.

C<signal> and C<end_of_events> are forwarded to every renderer.
Filters are not involved in lifecycle.

=head1 METHODS

=over 4

=item $om->add_renderer($renderer)

Register a renderer. Calls C<desired_filters> to build or share a filter
chain. Calls C<start> on the renderer. May be called multiple times.

=item $om->dispatch($event)

Send C<$event> through every pipeline. Each pipeline runs its filter chain
once; surviving events are passed to all renderers in that pipeline.

=item $om->finish

Call C<finish> on every renderer. Safe to call multiple times (idempotent).
Also called automatically via C<DESTROY>.

=item $om->signal($sig)

Forward signal C<$sig> to every renderer.

=item $om->end_of_events

Notify every renderer that the event stream has ended.

=back

=cut
