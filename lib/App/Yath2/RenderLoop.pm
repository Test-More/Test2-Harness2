package App::Yath2::RenderLoop;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Time::HiRes qw/sleep/;

use Test2::Harness2::Renderer::Base;

use Test2::Harness2::Util::HashBase qw{
    <renderers
    <producer
    <settings
    <run_id
    +plugins

    +sink
    +signalled
    +finished_sweep
    +idle
};

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::RenderLoop - Generic render loop: drive a pure event source (a
Producer) into the sink renderers, owning the dispatch fan-out, the sink
lifecycle, and the run rollup.

=head1 DESCRIPTION

The render loop is the same across C<test>, C<run>, C<watch>, and C<replay>: poll
a source for ready events, push each through the sink renderers (the jsonl log is
now one of them) and plugins, step the sinks each tick, and stop when the source
is exhausted. This
class is that loop, factored out of the command classes so it is written once and
reused for a live run, a flat event log, or (later) an archived database log.

It owns:

=over 4

=item *

The B<dispatch fan-out>: every event a producer yields is run through the sink
renderers' C<render_event> (the jsonl log is one of those renderers) and the
annotate/handle plugins (via a private L<Test2::Harness2::Renderer::Base> sink).

=item *

The B<sink lifecycle>: C<< $_->step >> each iteration, C<< $_->finish >> at the
end, and C<< $_->signal($sig) >> forwarding.

=item *

The B<run rollup>: the final pass/fail data, surfaced from the producer (a live
producer's per-job rollup, or a replayed log's recorded rollup).

=back

A B<Producer> (L<App::Yath2::RenderLoop::Producer>) is the pure source it drives:
C<poll> for ordered events, C<done> for end-of-source, optional C<finalize> for a
last flush. Swapping the producer is what makes the loop reusable across live and
archived runs.

=head1 SYNOPSIS

    my $loop = App::Yath2::RenderLoop->new(
        renderers => $renderers,
        producer  => $producer,
        settings  => $settings,
        run_id    => $run_id,
    );

    # The loop owns the iteration:
    $loop->start;
    # ...or with a per-iteration hook (e.g. reap a child):
    $loop->start(sub { $self->reap_runner });

    # ...or a command that owns its own loop drives one pass at a time:
    until ($loop->done) { $loop->iterate }
    $loop->finish;

    my $final_data   = $loop->final_data;
    my $tests_seen   = $loop->tests_seen;
    my $asserts_seen = $loop->asserts_seen;

=head1 ATTRIBUTES

=over 4

=item renderers

The sink renderers (C<render_event> consumers): the terminal formatter, the
jsonl log renderer, the DB / Server renderers, etc.

=item producer

The injected L<App::Yath2::RenderLoop::Producer>.

=item settings

=item run_id

The run settings and id, threaded into the dispatch sink.

=item plugins

The harness plugins (optional). Their C<annotate_event> / C<handle_event> hooks
run in the dispatch fan-out.

=back

=cut

sub init ($self) {
    croak "renderers is required" unless $self->{+RENDERERS};
    croak "producer is required"  unless $self->{+PRODUCER};

    $self->{+SIGNALLED} = 0;

    return;
}

=head1 PUBLIC METHODS

=over 4

=item $loop->iterate

Run one pass: step the sinks, poll the producer, dispatch the events it yields,
and (when the producer reports C<done>) run the producer's final flush + the
final-data sweep exactly once. Used by a command that owns its own loop and needs
other per-tick work. After C<done> returns true a further C<iterate> is a no-op.

=item $loop->start

=item $loop->start(sub { ... })

Run the loop to completion: C<iterate> until the producer is done. With a coderef,
it is invoked once per iteration (after the dispatch) for the command's own
per-tick work. Returns when the source is exhausted. Stops early if a signal was
delivered via C<signal>.

=item $bool = $loop->done

True once the producer is exhausted B<and> the final sweep has run (so a command
driving its own loop with C<iterate> knows the loop is complete).

=item $loop->finish

End-of-loop sink teardown: C<< $_->finish >> for every sink renderer. Idempotent
on the producer; safe to call once after the loop ends.

=item $loop->signal($sig)

Forward a signal to every sink renderer that can take one, and mark the loop so
C<start> stops iterating.

=item $data = $loop->final_data

=item $n = $loop->tests_seen

=item $n = $loop->asserts_seen

The run rollup and tallies. C<final_data> and C<tests_seen> come from the producer
(a live run's per-job rollup or a replayed log's recorded rollup); C<asserts_seen>
is the loop's own fan-out tally.

=back

=cut

sub done ($self) { return $self->{+FINISHED_SWEEP} ? 1 : 0 }

sub final_data ($self) { return $self->{+PRODUCER}->can('final_data') ? $self->{+PRODUCER}->final_data : undef }
sub tests_seen ($self) { return $self->{+PRODUCER}->can('tests_seen') ? $self->{+PRODUCER}->tests_seen : 0 }

sub asserts_seen ($self) { return $self->sink->asserts_seen }

sub signal ($self, $sig) {
    $self->{+SIGNALLED} = 1;

    for my $r (@{$self->{+RENDERERS}}) {
        next unless $r->can('signal');
        eval { $r->signal($sig); 1 } or warn $@;
    }

    return;
}

# The idle backoff between live-source polls that yield nothing, so the loop does
# not busy-spin waiting on the runner. A source that streams (a log) never idles
# (poll yields until done), so it pays no sleep.
sub IDLE_DELAY() { 0.02 }

sub start ($self, $each = undef) {
    until ($self->done) {
        last if $self->{+SIGNALLED};
        $self->iterate;
        $each->()        if $each;
        sleep IDLE_DELAY if $self->{+IDLE} && !$self->done;
    }

    return;
}

sub iterate ($self) {
    return if $self->{+FINISHED_SWEEP};

    my $producer = $self->{+PRODUCER};

    $_->step for @{$self->{+RENDERERS}};

    my @events = $producer->poll;
    $self->{+IDLE} = @events ? 0 : 1;
    $self->_dispatch($_) for @events;

    return unless $producer->done;

    # Source exhausted: one final flush from the producer (a live producer's final
    # sweep, which preserves the bounded-terminal-wait false-FAIL fix), dispatched
    # like any other events, then we are done.
    $self->{+FINISHED_SWEEP} = 1;
    $self->_dispatch($_) for $self->_finalize_producer;

    return;
}

sub finish ($self) {
    $_->finish for @{$self->{+RENDERERS}};
    return;
}

=head1 PRIVATE METHODS

=over 4

=item $self->sink

The private L<Test2::Harness2::Renderer::Base> used for the dispatch fan-out
(annotate plugins, C<render_event> -- the jsonl log is one of those renderers --
the assertion tally, handle plugins).

=item $self->_dispatch($event)

Fan one producer event out through the sink.

=item @events = $self->_finalize_producer

Call the producer's optional C<finalize> and return its trailing events.

=back

=cut

sub sink ($self) {
    return $self->{+SINK} //= Test2::Harness2::Renderer::Base->new(
        settings  => $self->{+SETTINGS},
        renderers => $self->{+RENDERERS},
        run_id    => $self->{+RUN_ID},
        plugins   => $self->{+PLUGINS} // [],
    );
}

sub _dispatch ($self, $e) {
    $self->sink->dispatch_to_sinks($e);
    return;
}

sub _finalize_producer ($self) {
    my $producer = $self->{+PRODUCER};
    return () unless $producer->can('finalize');
    return $producer->finalize;
}

1;

__END__

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

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

See F<http://dev.perl.org/licenses/>

=cut
