package App::Yath2::RenderLoop::LiveProducer;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Time::HiRes qw/time sleep/;

use Test2::Harness2::Runner::Monitor;

use Test2::Harness2::Util::HashBase qw{
    <engine
    <subscriber
    +monitor
    <done_check
    <runner_output_only

    +queue
    +finalized
};

use Role::Tiny::With;
with 'App::Yath2::RenderLoop::Producer';

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::RenderLoop::LiveProducer - Render-loop producer that mirrors a live
runner and yields its per-job-ordered events.

=head1 DESCRIPTION

A L<App::Yath2::RenderLoop::Producer> for a B<live> run. It owns a runner
subscription mirror (a L<Test2::Harness2::Runner::Subscriber> feeding a
L<Test2::Harness2::Runner::Monitor>) and a render B<engine>
(L<Test2::Harness2::Renderer::Driver> for C<test>/C<run>, or the plainer
L<Test2::Harness2::Renderer::Base> for C<watch>'s runner-output-only view). On
each C<poll> it polls the subscription and drives the engine one step; the engine
emits the ordered events through its C<dispatch_cb>, which this producer collects
and returns. The engine's dispatch fan-out, log writing, plugins, and the run
rollup (C<compute_final>) all live in L<App::Yath2::RenderLoop>, not here -- this
producer is a pure source.

Completion is decided by an injected C<done_check> coderef so the same producer
serves every live shape: socket-closed for the transient C<test> runner,
C<run_done> for the persistent C<run> runner, runner-process-gone when the
subscription never connected, and pfile/socket-gone for C<watch>.

The per-job ordering, the bounded events-file terminal wait, and the final sweep
are the engine's (L<Test2::Harness2::Renderer::Driver>), reused verbatim so the
prior false-FAIL fix (a passing job rendered FAILED when its completion was
settled off a transient EOF before its terminal flushed) is preserved.

=head1 SYNOPSIS

    my $producer = App::Yath2::RenderLoop::LiveProducer->new(
        engine     => $driver,                       # Renderer::Driver
        subscriber => $sub,                           # or undef (no-runner fallback)
        done_check => sub { $sub ? $sub->closed : $runner_gone->() },
    );

    my $loop = App::Yath2::RenderLoop->new(renderers => $renderers, producer => $producer);
    $loop->start;

=head1 ATTRIBUTES

=over 4

=item engine

The render engine. A L<Test2::Harness2::Renderer::Driver> (per-job ordering) or a
L<Test2::Harness2::Renderer::Base> (runner-output only, for C<watch>). This
producer installs a C<dispatch_cb> on it so the events it would render are
collected instead of fanned out.

=item subscriber

The L<Test2::Harness2::Runner::Subscriber> mirror, or C<undef> when the runner
never bound its socket (the engine still tails runner output from disk so the
runner's own failure renders).

=item done_check

A coderef returning true once the source is exhausted (socket EOF / C<run_done> /
runner gone / pfile gone). Defaults to "subscriber closed, or true if there is no
subscriber".

=item runner_output_only

When true (the C<watch> view) C<poll> tails only runner/service output and never
runs per-job ordering or a final rollup. Defaults to true when the engine cannot
do per-job ordering (a plain L<Test2::Harness2::Renderer::Base>).

=back

=cut

sub init ($self) {
    croak "engine is required" unless $self->{+ENGINE};

    $self->{+MONITOR} //= $self->{+SUBSCRIBER} ? $self->{+SUBSCRIBER}->monitor : Test2::Harness2::Runner::Monitor->new;

    $self->{+RUNNER_OUTPUT_ONLY} //= $self->{+ENGINE}->can('step') ? 0 : 1;

    $self->{+QUEUE}     = [];
    $self->{+FINALIZED} = 0;

    # The engine renders by dispatching; redirect that dispatch into our queue so
    # poll() is a pure source and the loop owns the actual sink fan-out.
    my $queue = $self->{+QUEUE};
    $self->{+ENGINE}->set_dispatch_cb(sub ($e) {
        push @{$queue} => $e;
    });

    return;
}

=head1 PUBLIC METHODS

=over 4

=item $mon = $producer->monitor

The runner-state mirror this producer reads.

=item @events = $producer->poll

Poll the subscription, drive the engine one step (per-job ordering, or
runner-output-only for C<watch>), and return the ordered events the engine
emitted this tick.

=item $bool = $producer->done

True once the injected C<done_check> reports the source exhausted.

=item @events = $producer->finalize

A final drain + the engine's final sweep + the run rollup (per-job mode only),
returning any trailing events. The loop dispatches them, then reads
C<final_data> / C<tests_seen> / C<asserts_seen>.

=item $data = $producer->final_data

=item $n = $producer->tests_seen

=item $n = $producer->asserts_seen

The engine's computed run rollup and tallies, valid after C<finalize>.

=back

=cut

sub done ($self) { return $self->done_check_value ? 1 : 0 }

sub final_data   ($self) { return $self->{+ENGINE}->final_data }
sub tests_seen   ($self) { return $self->{+ENGINE}->tests_seen }
sub asserts_seen ($self) { return $self->{+ENGINE}->asserts_seen }

sub poll ($self) {
    my $sub = $self->{+SUBSCRIBER};
    $sub->poll if $sub;

    my $engine  = $self->{+ENGINE};
    my $monitor = $self->{+MONITOR};

    if ($self->{+RUNNER_OUTPUT_ONLY}) {
        $engine->step_runner_output($monitor);
    }
    else {
        $engine->step($monitor);
    }

    return $self->_drain_queue;
}

sub finalize ($self) {
    return () if $self->{+FINALIZED};
    $self->{+FINALIZED} = 1;

    my $sub     = $self->{+SUBSCRIBER};
    my $engine  = $self->{+ENGINE};
    my $monitor = $self->{+MONITOR};

    # poll() drains all buffered frames before flagging EOF, so the mirror is
    # whole; drain once more to fold anything batched with the close.
    $sub->poll if $sub;

    # Pull the runner's trailing output into the stream before the rollup (the
    # runner can close its socket before its collector parent flushes the last
    # print into runner-events).
    $self->_drain_runner_output;

    # The engine's per-job final sweep + run rollup (Renderer::Driver::finalize):
    # the bounded events-file terminal wait it performs is what fixed a prior
    # false-FAIL, so it is reused unchanged here.
    $engine->finalize($monitor) if $engine->can('finalize');

    return $self->_drain_queue;
}

=head1 PRIVATE METHODS

=over 4

=item $bool = $self->done_check_value

Evaluate the injected C<done_check> (or the default socket-EOF check).

=item @events = $self->_drain_queue

Take and clear the events the engine collected via its C<dispatch_cb>.

=item $self->_drain_runner_output

On completion, keep tailing the runner's own events file until its terminal
record is read (or a bounded timeout), so the runner's trailing output lands in
the log before the rollup. A persistent runner still serving its socket is not
exiting, so a single tail pass suffices and we do not block.

=back

=cut

# How long to wait, at most, for the runner's collector to flush the runner's
# trailing stdout into runner-events after the runner has signalled completion.
# Bounded so a runner whose collector never writes its terminal cannot hang the
# command; the drain is condition-driven and this is only the fallback.
sub DRAIN_RUNNER_OUTPUT_TIMEOUT() { 5 }

sub done_check_value ($self) {
    if (my $check = $self->{+DONE_CHECK}) {
        return $check->() ? 1 : 0;
    }

    my $sub = $self->{+SUBSCRIBER};
    return 1 unless $sub;
    return $sub->closed ? 1 : 0;
}

sub _drain_queue ($self) {
    my $queue = $self->{+QUEUE};
    return () unless @{$queue};
    my @out = @{$queue};
    @{$queue} = ();
    return @out;
}

sub _drain_runner_output ($self) {
    my $engine  = $self->{+ENGINE};
    my $monitor = $self->{+MONITOR};
    my $sub     = $self->{+SUBSCRIBER};

    return unless $engine->can('step_runner_output');

    # A single tail pass always; enough when the runner output is already complete.
    $engine->step_runner_output($monitor);

    # Persistent runner still serving (socket open) -- not exiting, so there is no
    # runner terminal to wait for. Do not block.
    return if $sub && !$sub->closed;

    return unless $engine->can('runner_output_done');

    my $start = time;
    until ($engine->runner_output_done) {
        last       if (time - $start) > DRAIN_RUNNER_OUTPUT_TIMEOUT;
        $sub->poll if $sub;
        $engine->step_runner_output($monitor);
        sleep 0.02;
    }

    return;
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
