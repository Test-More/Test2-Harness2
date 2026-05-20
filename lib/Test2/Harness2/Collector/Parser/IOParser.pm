package Test2::Harness2::Collector::Parser::IOParser;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;

use Test2::Harness2::Event;

use Object::HashBase;
use Role::Tiny::With;
with 'Test2::Harness2::Collector::Role::Parser';

sub parse_io {
    my $self = shift;
    my (%params) = @_;

    croak "No 'stream' provided" unless defined $params{stream};

    return undef unless defined $params{line} || defined $params{event};

    my $event = $self->get_event(%params);

    $self->parse_stream_line(\%params, $event) if defined $params{line};

    delete $event->{event_id};

    $event->{compressed_form} = $params{compressed}
        if defined $params{compressed};

    return $event;
}

sub get_event {
    my $self = shift;
    my (%params) = @_;

    if (my $ev = $params{event}) {
        return $ev if blessed($ev);
        return Test2::Harness2::Event->new(%$ev);
    }

    return Test2::Harness2::Event->new(facet_data => {});
}

sub parse_stream_line {
    my $self = shift;
    my ($io, $event) = @_;

    my $stream   = $io->{stream};
    my $ucstream = uc($stream);
    my $text     = $io->{line};

    $event->{facet_data}{from_stream} = {source => $ucstream, details => $text};

    push @{$event->{facet_data}{info}} => {
        details => $text,
        tag     => $ucstream,
        debug   => ($ucstream eq 'STDERR' ? 1 : 0),
    };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Parser::IOParser - Base parser; turns raw stream
lines into events.

=head1 DESCRIPTION

The default parser used by L<Test2::Harness2::Collector>. Each line of input
becomes a single L<Test2::Harness2::Event> whose facet data carries a
C<from_stream> facet and a matching C<info> entry tagged with the uppercased
stream name. Pre-decoded event bursts (JSON messages from
L<Test2::Formatter::Stream2>) pass through with their event hashref
rehydrated into a L<Test2::Harness2::Event>.

This class consumes L<Test2::Harness2::Collector::Role::Parser>. Subclasses
that want to recognize richer line protocols (TAP, JSON, custom framing)
override L</parse_stream_line>; see
L<Test2::Harness2::Collector::Parser::TAPParser>.

=head1 SYNOPSIS

    use Test2::Harness2::Collector::Parser::IOParser;

    my $parser = Test2::Harness2::Collector::Parser::IOParser->new;

    my $event = $parser->parse_io(stream => 'stdout', line => 'hello');
    # $event->facet_data->{from_stream}{source}  eq 'STDOUT'
    # $event->facet_data->{from_stream}{details} eq 'hello'
    # $event->facet_data->{info}[0]{tag}         eq 'STDOUT'

=head1 PUBLIC METHODS

=over 4

=item $event = $parser->parse_io(stream => $s, line => $l, event => $e, compressed => $bytes)

Turn one unit of input into one event. Returns C<undef> when neither C<line>
nor C<event> is defined. The wire-level C<event_id> (used by the collector
to pair STDOUT bursts with STDERR sync markers) is stripped from the event
before return so it does not bleed into downstream consumers. When
C<compressed> is supplied, its bytes are stashed in the event's
C<compressed_form> slot for zstd-aware recorders.

=item $event = $parser->get_event(%params)

Construct (or rehydrate) the L<Test2::Harness2::Event> the line will be
written into. When C<%params> carries an C<event> entry (either a blessed
event or a plain hashref), that event is returned; otherwise a fresh event
with an empty C<facet_data> hash is built.

=item $parser->parse_stream_line(\%io, $event)

Populate C<< $event->{facet_data} >> from a line of stream input. The base
implementation attaches the C<from_stream> facet and pushes a single
C<info> entry tagged with the uppercased stream name (C<debug = 1> for
STDERR, C<0> otherwise). Subclasses override this method to recognize
richer line shapes; an override that does not handle the line may call
C<< $self->SUPER::parse_stream_line(\%io, $event) >> to keep the raw
fallback.

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
