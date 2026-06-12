package Test2::Harness2::Event;
use v5.38;

our $VERSION = '2.000000';

use Test2::Harness2::Util::JSON qw/encode_json/;

use Object::HashBase qw{
    <facet_data
    <compressed_form
    +_json
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Event - The harness's single event class.

=head1 DESCRIPTION

A small L<Object::HashBase> class everything in the harness emits. The whole
payload lives in C<facet_data> (the Test2 facet hash); the harness does not
stamp identifiers, ordinals, or timestamps onto the event. Identity is
position in the events stream; canonical homes for timing / process data are
the facets that own them (C<trace.stamp>, C<trace.pid>, C<trace.tid>, etc.).

Events are expected to arrive already clean -- producers (the stream
formatter and the collector's line parser) strip empty facets and redundant
fields before the event reaches the events file. Nothing downstream re-cleans
them.

=head1 SYNOPSIS

    use Test2::Harness2::Event;

    my $e = Test2::Harness2::Event->new(
        facet_data => { info => [{ tag => 'NOTE', details => 'hi' }] },
    );

    my $json = $e->as_json;

=head1 ATTRIBUTES

=over 4

=item facet_data

Hashref of Test2 facet data. Defaults to an empty hashref if the caller does
not supply one.

=item compressed_form

The on-wire zstd frame the collector captured for an event that arrived as a
message burst. When present, the events-file writer appends it verbatim
instead of re-encoding. A consumer that mutates the event must call
L</clear_compressed_form> so the stale frame is not written.

=back

=cut

sub init ($self) {
    $self->{+FACET_DATA} //= {};
    return;
}

=head1 PUBLIC METHODS

=cut

=over 4

=item $json = $e->as_json

JSON-encoded form of the event. Cached on the event so subsequent calls
return the same string.

=item clear_compressed_form

=item $e->clear_compressed_form

Drop the cached on-wire compressed frame (and the cached JSON encoding that
pairs with it). A consumer that mutates the event must call this so a
downstream zstd writer does not emit bytes that no longer match the event.

=back

=cut

sub as_json ($self) {
    return $self->{+_JSON} //= encode_json($self);
}

sub clear_compressed_form ($self) {
    delete $self->{+COMPRESSED_FORM};
    delete $self->{+_JSON};
    return;
}

=over 4

=item $hashref = $e->TO_JSON

Hashref form used by L<Cpanel::JSON::XS>'s C<convert_blessed>. Drops the
internal cache slots (C<_json>, C<compressed_form>); the event is otherwise
serialized as-is, since producers already delivered it clean.

=back

=cut

sub TO_JSON ($self) {
    my $out = {%$self};

    delete $out->{+_JSON};
    delete $out->{+COMPRESSED_FORM};

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
