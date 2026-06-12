package Test2::Harness2::Util::JSON;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/confess/;
use Cpanel::JSON::XS ();
use Importer Importer => 'import';

our @EXPORT_OK = qw{
    decode_json
    encode_json
    encode_pretty_json
    json_false
    json_true
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::JSON - Thin JSON helpers used across the harness.

=head1 DESCRIPTION

Wraps L<Cpanel::JSON::XS> with the encoder / decoder configurations the
harness relies on: a UTF-8 decoder, an ASCII-safe encoder for messages that
travel through plain handles, and a pretty / canonical encoder for
human-facing files.

=head1 SYNOPSIS

    use Test2::Harness2::Util::JSON qw/encode_json decode_json/;

    my $json = encode_json({ ... });
    my $data = decode_json($json);

=head1 EXPORTS

All exports are optional and must be requested explicitly.

=cut

my $JSON   = Cpanel::JSON::XS->new->utf8(1)->convert_blessed(1)->allow_nonref(1);
my $ASCII  = Cpanel::JSON::XS->new->ascii(1)->convert_blessed(1)->allow_nonref(1);
my $PRETTY = Cpanel::JSON::XS->new->ascii(1)->pretty(1)->canonical(1)->convert_blessed(1)->allow_nonref(1);

=over 4

=item $bool = json_true()

=item $bool = json_false()

The canonical L<Cpanel::JSON::XS> boolean values, useful when building
structures destined for L</encode_json>.

=back

=cut

sub json_true  { Cpanel::JSON::XS->true }
sub json_false { Cpanel::JSON::XS->false }

=over 4

=item $data = decode_json($json)

Decode UTF-8 JSON text. Confesses on decoding errors.

=back

=cut

sub decode_json ($json_text) {
    my $out;
    confess($@) unless eval { $out = $JSON->decode($json_text); 1 };
    return $out;
}

=over 4

=item encode_json

=item $json = encode_json($data)

Encode C<$data> to ASCII-safe JSON. Confesses on encoding errors.

=back

=cut

sub encode_json ($data) {
    my $out;
    confess($@) unless eval { $out = $ASCII->encode($data); 1 };
    return $out;
}

=over 4

=item $json = encode_pretty_json($data)

Encode C<$data> to ASCII-safe, pretty-printed, canonical (sorted-key) JSON,
suitable for files a human will read. Confesses on encoding errors.

=back

=cut

sub encode_pretty_json ($data) {
    my $out;
    confess($@) unless eval { $out = $PRETTY->encode($data); 1 };
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
