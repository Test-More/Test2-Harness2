package Test2::Harness2::Event;
use strict;
use warnings;

our $VERSION = '2.000000';

use Test2::Harness2::Util::JSON qw/encode_json/;

use Object::HashBase qw{
    <facet_data
    <stream_id
    <event_id
    <stamp
    +_json
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Event - The harness's single event class.

=head1 DESCRIPTION

A small L<Object::HashBase> class everything in the harness emits.
The on-wire payload lives in C<facet_data> (the Test2 facet hash); a
few top-level attributes carry the identifiers and timing the
collector / recorder pipeline needs to route the event without
descending into facet data.

=head1 SYNOPSIS

    use Test2::Harness2::Event;

    my $e = Test2::Harness2::Event->new(
        facet_data => { harness => { kind => 'lifecycle' } },
        stream_id  => 'events',
        event_id   => $uuid,
        stamp      => $ts,
    );

    my $json = $e->as_json;

=head1 ATTRIBUTES

=over 4

=item facet_data

Hashref of Test2 facet data. Defaults to an empty hashref if the
caller does not supply one.

=item stream_id

Identifier of the stream the event belongs to (e.g. C<events>,
C<stdout>, C<stderr>). Used by the recorder to route the event into
the right artifact.

=item event_id

Per-event identifier (UUID v7 in normal use). May be C<undef> for
events that do not carry one.

=item stamp

Event timestamp in seconds since the epoch (fractional, hi-res).

=back

=cut

sub init {
    my $self = shift;
    $self->{+FACET_DATA} //= {};
}

=head1 PUBLIC METHODS

=cut

=over 4

=item as_json

=item $json = $e->as_json

JSON-encoded form of the event. Cached on the event so subsequent
calls return the same string.

=back

=cut

sub as_json {
    my $self = shift;
    return $self->{+_JSON} //= encode_json($self);
}

=over 4

=item clear_json_cache

=item $e->clear_json_cache

Drop the cached JSON encoding. Callers that mutate the event after
constructing it must call this so a downstream encoder does not
return the stale string.

=back

=cut

sub clear_json_cache {
    my $self = shift;
    delete $self->{+_JSON};
    return;
}

=over 4

=item TO_JSON

=item $hashref = $e->TO_JSON

Hashref form used by L<Cpanel::JSON::XS>'s C<convert_blessed>. Drops
the cached JSON string and strips empty facets (C<{}> / C<[]>) from
C<facet_data> at serialization time.

=back

=cut

sub TO_JSON {
    my $self = shift;
    my $out  = {%$self};

    delete $out->{+_JSON};

    if (my $fd = $out->{+FACET_DATA}) {
        my %copy;
        for my $key (keys %$fd) {
            my $val = $fd->{$key};
            if (ref($val) eq 'HASH') {
                next unless keys %$val;
            }
            elsif (ref($val) eq 'ARRAY') {
                next unless @$val;
            }
            $copy{$key} = $val;
        }
        $out->{+FACET_DATA} = \%copy;
    }

    return $out;
}

1;

__END__

=pod

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

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
