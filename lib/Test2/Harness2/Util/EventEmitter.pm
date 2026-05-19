package Test2::Harness2::Util::EventEmitter;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;
use Atomic::Pipe;
use Test2::Util::UUID qw/gen_uuid/;

use Test2::Harness2::Util::IPC qw/apply_atomic_pipe_compression/;
use Test2::Harness2::Util::JSON qw/encode_json/;

use Object::HashBase qw{
    <stdout_pipe
    <stderr_pipe
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::EventEmitter - Write structured events to an
Atomic::Pipe without loading Test2::API.

=head1 DESCRIPTION

A small standalone helper that writes structured events to an
L<Atomic::Pipe> in mixed-data mode using the same wire format that
L<Test2::Formatter::Stream2> uses. Services and harness infrastructure
code use it to emit lifecycle events that an existing collector can
read without loading the L<Test2::API> hub.

Each call to L</emit_event> writes one atomic JSON message burst to
the stdout pipe and -- when L</stderr_pipe> is set -- a tiny
C<{"event_id":"..."}> sync marker to the stderr pipe so the collector
can order STDOUT bursts relative to interleaved STDERR text.

=head1 SYNOPSIS

    use Test2::Harness2::Util::EventEmitter;

    my $emitter = Test2::Harness2::Util::EventEmitter->new;
    $emitter->emit_event(kind => 'lifecycle', note => 'starting up');

    use Atomic::Pipe;
    my ($r, $w) = Atomic::Pipe->pair(mixed_data_mode => 1);
    my $emitter = Test2::Harness2::Util::EventEmitter->new(stdout_pipe => $w);

=head1 ATTRIBUTES

Both attributes accept one of: a pre-built L<Atomic::Pipe> in
C<mixed_data_mode>, any filehandle that L<Atomic::Pipe/from_fh> can
promote (C<\*STDOUT>, an L<IO::Handle>, etc.), or C<undef> to take
the default.

=over 4

=item stdout_pipe

The pipe the main JSON event bursts land on. Defaults to wrapping
C<\*STDOUT>.

=item stderr_pipe

The pipe the C<{"event_id":"..."}> sync marker lands on when set.
When neither given nor C<undef>, the default is determined from
C<$ENV{T2_HARNESS2_PIPE_COUNT}>: C<2> means STDOUT and STDERR are
separate mixed-mode pipes; C<1> means they are merged onto the same
pipe and the emitter leaves the slot empty to avoid writing a
duplicate marker.

=back

=cut

sub init {
    my $self = shift;

    $self->{+STDOUT_PIPE} = $self->_as_atomic_pipe($self->{+STDOUT_PIPE} // \*STDOUT);

    if (exists $self->{+STDERR_PIPE}) {
        $self->{+STDERR_PIPE} = $self->_as_atomic_pipe($self->{+STDERR_PIPE})
            if defined $self->{+STDERR_PIPE};
    }
    else {
        my $pipe_count = $ENV{T2_HARNESS2_PIPE_COUNT} // 1;
        $self->{+STDERR_PIPE} = $self->_as_atomic_pipe(\*STDERR) if $pipe_count > 1;
    }
}

=head1 PUBLIC METHODS

=cut

=over 4

=item std

=item $emitter = Test2::Harness2::Util::EventEmitter->std

Process-wide cached emitter for the default STDOUT/STDERR pair. The
first call instantiates it via C<new> with no arguments; every
subsequent call returns that instance. Fork-safe: the cache is keyed
on C<$$>, and after a fork the child's first C<std> call sees the
stale pid and rebuilds from its own (possibly redirected)
STDOUT/STDERR.

=back

=cut

{
    my $CACHED;
    my $CACHED_PID;

    sub std {
        my $class = shift;
        return $CACHED if $CACHED && defined($CACHED_PID) && $CACHED_PID == $$;
        $CACHED_PID = $$;
        return $CACHED = $class->new;
    }
}

=over 4

=item emit_event

=item $event_id = $emitter->emit_event(%fields)

Build a harness-facet event, encode it as JSON, write it to
L</stdout_pipe>, and optionally write the STDERR sync marker to
L</stderr_pipe>. C<%fields> are merged into the C<harness> facet.
Returns the UUID assigned to the event.

=back

=cut

sub emit_event {
    my ($self, %fields) = @_;

    my $event = {
        facet_data => {
            harness => {%fields},
        },
    };

    return $self->emit_raw($event);
}

=over 4

=item emit_raw

=item $event_id = $emitter->emit_raw($event_hashref)

Write a pre-built event hashref as-is: encode to JSON, write the
burst to L</stdout_pipe>, and -- if L</stderr_pipe> is set -- write
C<{"event_id":"..."}> to it. Returns the wire-level event id.

=back

=cut

sub emit_raw {
    my ($self, $event) = @_;

    my $sync_id = gen_uuid();
    $event->{event_id} = $sync_id;

    my $json = encode_json($event);

    delete $event->{event_id};

    $self->{+STDOUT_PIPE}->write_message($json);

    if (my $se = $self->{+STDERR_PIPE}) {
        $se->write_message(qq/{"event_id":"$sync_id"}/);
    }

    return $sync_id;
}

sub _as_atomic_pipe {
    my $self = shift;
    my ($in) = @_;

    return $in if blessed($in) && $in->isa('Atomic::Pipe');

    my $apipe = Atomic::Pipe->from_fh('>&=', $in);
    $apipe->set_mixed_data_mode();
    apply_atomic_pipe_compression($apipe);
    return $apipe;
}

1;

__END__

=pod

=head2 ORDERING NOTE

C<Atomic::Pipe> in C<mixed_data_mode> does B<not> guarantee FIFO
ordering between plain C<print>/C<warn> writes and C<write_message>
calls on the same pipe fd, even when both come from the same
process. The sync-marker contract (every STDOUT event is paired
with a STDERR sync marker) lets the collector order STDOUT events
relative to STDERR lines, but it cannot reorder items that have
already been delivered out of sequence within the same stream.

In practice this only matters in contrived test scenarios that drive
a tight C<print> / C<write_message> loop on the same pipe fd. Normal
test processes via L<Test2::Formatter::Stream2> are not affected.

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

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
