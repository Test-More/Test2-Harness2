package Test2::Harness2::Service::Sampler;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use POSIX qw/ceil/;
use Time::HiRes qw/time/;

use Test2::Collector::Util::EventEmitter;

use Test2::Harness2::SystemLoad;

use Test2::Harness2::Util::HashBase qw{
    <workdir
    <name
    <interval
    <decrease_delay
    <runner_socket
    <source
    +conn
    +next_at
    +metrics
    +emitter
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Service';

use constant DEFAULT_INTERVAL       => 0.2;
use constant DEFAULT_DECREASE_DELAY => 1.0;

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Service::Sampler - Dedicated process that samples system load.

=head1 DESCRIPTION

A minimal service whose only job is to sample CPU and memory load on a fixed
cadence and report changes to the runner. Because the process does nothing else,
its loop interval is steady -- which matters: CPU percentage is computed from the
delta between two readings, so a consistent interval is what makes the number
meaningful.

It samples every tick, but does not report every sample. Both CPU and memory
usage are rounded B<up> to the nearest 5%, and a C<system_load> message is sent
only when one of those rounded values B<changes> enough to warrant it. The same
policy applies to each metric independently:

=over 4

=item *

An B<increase> is reported immediately (load going up matters now).

=item *

A B<decrease> is only reported once the rounded value has stayed below the
last-sent value for at least L</decrease_delay> seconds -- a brief dip is not
trusted as a real drop.

=item *

No change (or a same-valued plateau) sends nothing.

=back

A message is sent when B<either> CPU or memory triggers, and it carries the
current rounded value of both (plus the load average, which rides along). The
reported C<cpu_pct> / C<mem_pct> are the rounded values.

Each reported snapshot is B<also> emitted as a structured C<harness_system> facet
event into the sampler's own collector event stream (via
L<Test2::Collector::Util::EventEmitter>), giving every snapshot a durable home in
the sampler's own C<sampler-events.jsonl.zst> events stream, in addition to the
live one-way report to the runner. C<harness_system> has no render path, so this
durable record is never shown as a line by the default renderer; archive / replay
consumers pick it up by that facet.

It consumes L<Test2::Harness2::Role::Service> for the shared connection model: it
dials the runner's socket and identifies, then sends one-way C<system_load>
requests over that connection. It never serves requests of its own. The sampler
stops if that connection breaks (a failed write, or the runner closing it).

=head1 ATTRIBUTES

=over 4

=item interval

Seconds between samples. Defaults to 0.2.

=item decrease_delay

Seconds a lower rounded metric value (cpu or memory) must persist before a
decrease is reported. Defaults to 1.0 (five ticks at the default interval).

=item runner_socket (required)

Path to the runner's socket to report snapshots to.

=item workdir (required)

Working directory (for the role's own -- unused -- listen socket).

=item name

Service name. Defaults to C<sampler>.

=item source

The L<Test2::Harness2::SystemLoad> instance. Vivified by default.

=back

=cut

sub init ($self) {
    $self->{+NAME}           //= 'sampler';
    $self->{+INTERVAL}       //= DEFAULT_INTERVAL;
    $self->{+DECREASE_DELAY} //= DEFAULT_DECREASE_DELAY;
    $self->{+SOURCE}         //= Test2::Harness2::SystemLoad->new;
    $self->{+METRICS}        //= {};

    croak "'workdir' is required"
        unless defined $self->{+WORKDIR} && length $self->{+WORKDIR};
    croak "'runner_socket' is required"
        unless defined $self->{+RUNNER_SOCKET} && length $self->{+RUNNER_SOCKET};

    return;
}

=head1 PUBLIC METHODS

=cut

=over 4

=item $self->run

Bind the (unused) listen socket, dial the runner, then loop: service the socket,
sample on the cadence, and report changes until the connection breaks or the
runner asks the sampler to stop. Returns when the loop exits.

=item $self->service_tick

Once per C<interval>, take a snapshot and report it only when the rounded CPU or
memory usage changed enough to warrant it. Stops if the runner connection has gone
away.

=back

=cut

sub run ($self) {
    $self->start_service;

    $self->{+CONN} = $self->service_connect_peer('runner', $self->{+RUNNER_SOCKET})
        or croak "sampler could not connect to the runner socket '$self->{+RUNNER_SOCKET}'";

    $self->{+NEXT_AT} = time;    # sample on the first tick

    until ($self->service_stopped) {
        # Drive the connection: the identity handshake reply and a runner 'stop'
        # both arrive here, and a vanished runner surfaces as a closed connection.
        $self->service_io;
        last if $self->{+CONN}->closed;

        $self->service_tick;

        Time::HiRes::sleep($self->{+INTERVAL} / 4);
    }

    $self->close_service;

    return;
}

sub service_tick ($self) {
    my $now = time;
    return if $now < $self->{+NEXT_AT};

    # Advance by whole intervals; resync if we fell more than an interval behind
    # (a stall should not produce a burst of catch-up samples).
    $self->{+NEXT_AT} += $self->{+INTERVAL};
    $self->{+NEXT_AT} = $now + $self->{+INTERVAL} if $self->{+NEXT_AT} < $now;

    # A vanished runner closes the connection; stop instead of writing into it.
    if ($self->{+CONN}->closed) {
        $self->stop_service;
        return;
    }

    # Always sample (keeps the CPU delta accurate); only report on a change.
    my $snap = $self->{+SOURCE}->sample;

    my $cpu = defined $snap->{cpu_pct} ? $self->_round_up_5($snap->{cpu_pct}) : undef;
    my $mem = defined $snap->{mem_pct} ? $self->_round_up_5($snap->{mem_pct}) : undef;

    # Track BOTH metrics every tick (do not short-circuit -- each needs its
    # decrease window updated), then send if either says so.
    my $cpu_trig = defined $cpu ? $self->_metric_triggers('cpu', $cpu, $now) : 0;
    my $mem_trig = defined $mem ? $self->_metric_triggers('mem', $mem, $now) : 0;
    return unless $cpu_trig || $mem_trig;

    # A message reports the current rounded value of every metric, so commit them
    # all (whichever triggered, both are now "last sent").
    $self->_commit_metric('cpu', $cpu) if defined $cpu;
    $self->_commit_metric('mem', $mem) if defined $mem;

    $snap->{cpu_pct} = $cpu if defined $cpu;
    $snap->{mem_pct} = $mem if defined $mem;

    # ALSO emit the snapshot into the sampler's own collector event stream, so it
    # rides into the events file (sampler-events.jsonl.zst) as a durable record for
    # archive / replay consumers. It is emitted as a structured harness_system
    # facet event (NOT a raw print): the default renderer has no render path for
    # harness_system, so it is never shown as a line, while the monitor and any
    # archive consumer pick it up by that facet -- the same shape the live one-way
    # report folds into runner state.
    $self->_emit_load_event($snap);

    # One-way request: the runner's handler stores the snapshot and returns no
    # response. service_send returns false if the write failed (the runner
    # vanished mid-write, closing the connection) -- stop in that case.
    $self->stop_service
        unless $self->service_send('runner', 'system_load', load => $snap);

    return;
}

sub _emit_load_event ($self, $snap) {
    my $emitter = $self->_emitter or return;

    # Best effort: a captured-stream write failure must not take the sampler
    # down -- the live service_send report is the load path the runner needs.
    local $SIG{PIPE} = 'IGNORE';
    eval {
        $emitter->emit_raw({facet_data => {harness_system => $snap}});
        1;
    };

    return;
}

# The event emitter the durable snapshot is written through. The default is the
# collector's captured-STDOUT emitter (EventEmitter->std), which is only
# meaningful inside the collector child that wraps the sampler -- that is where
# STDOUT is the event pipe. T2_COLLECTOR_PIPE_COUNT is set by Test2::Collector in
# every child it wraps; outside one there is nothing to capture the event and the
# emitter's binary frame would corrupt a plain STDOUT, so we emit nothing. A test
# may inject its own emitter to bypass that gate.
sub _emitter ($self) {
    return $self->{+EMITTER} if defined $self->{+EMITTER};
    return undef unless defined $ENV{T2_COLLECTOR_PIPE_COUNT};
    return $self->{+EMITTER} = Test2::Collector::Util::EventEmitter->std;
}

=head1 PRIVATE METHODS

=cut

=over 4

=item $self->_emit_load_event($snap)

Emit one snapshot as a structured C<harness_system> facet event into the
sampler's own collector event stream (via L<Test2::Collector::Util::EventEmitter>),
so it is recorded in C<sampler-events.jsonl.zst> as a durable record (in addition
to the live one-way report to the runner). It is deliberately B<not> a raw print:
a captured raw line would be wrapped as an C<INTERNAL>-tagged info line and shown
by the default renderer, whereas C<harness_system> has no render path and is
instead consumed by the monitor / archive consumers by that facet.

=item $bool = $self->_metric_triggers($name, $rounded, $now)

Apply the reporting policy to one metric's rounded value and return whether it
warrants sending a message. Tracks the metric's decrease window as a side effect
(so it must be called every tick), but does B<not> update the last-sent value --
that happens in C<_commit_metric> once a send is decided. The initial reading and
any increase trigger immediately; a decrease triggers only once the lower value
has held for L</decrease_delay> seconds; an unchanged value triggers nothing and
clears any pending decrease window.

=item $self->_commit_metric($name, $rounded)

Record C<$rounded> as the metric's last-sent value and clear its decrease window.

=item $n = $self->_round_up_5($pct)

Round a percentage B<up> to the nearest multiple of 5, capped at 100.

=back

=cut

sub _metric_triggers ($self, $name, $rounded, $now) {
    my $m    = $self->{+METRICS}{$name} //= {};
    my $last = $m->{last_sent};

    return 1 if !defined $last;      # initial reading
    return 1 if $rounded > $last;    # increase: report now

    if ($rounded == $last) {         # unchanged: clear any decrease window
        delete $m->{decrease_since};
        return 0;
    }

    # Decrease: only trusted once it has persisted for decrease_delay.
    $m->{decrease_since} //= $now;
    return (($now - $m->{decrease_since}) >= $self->{+DECREASE_DELAY}) ? 1 : 0;
}

sub _commit_metric ($self, $name, $rounded) {
    my $m = $self->{+METRICS}{$name} //= {};
    $m->{last_sent} = $rounded;
    delete $m->{decrease_since};
    return;
}

sub _round_up_5 ($self, $pct) {
    # Subtract a tiny epsilon so a value already on a 5% boundary is not bumped
    # to the next bucket by floating-point noise.
    my $bucket = ceil(($pct / 5) - 1e-9);
    $bucket = 0 if $bucket < 0;
    my $r = 5 * $bucket;
    return $r > 100 ? 100 : $r;
}

1;

__END__

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

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
