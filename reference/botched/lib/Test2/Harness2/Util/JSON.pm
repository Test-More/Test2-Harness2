package Test2::Harness2::Util::JSON;
use strict;
use warnings;

use Carp qw/confess croak/;
use Cpanel::JSON::XS();

our $VERSION = '2.000012';

use Exporter 'import';

our @EXPORT_OK = qw{
    decode_json
    encode_json
    encode_pretty_json

    json_true
    json_false
};

my $json   = Cpanel::JSON::XS->new->utf8(1)->convert_blessed(1)->allow_nonref(1);
my $ascii  = Cpanel::JSON::XS->new->ascii(1)->convert_blessed(1)->allow_nonref(1);
my $pretty = Cpanel::JSON::XS->new->ascii(1)->pretty(1)->canonical(1)->convert_blessed(1)->allow_nonref(1);

sub decode_json {
    my $out;
    my $ok  = eval { $out = $json->decode(@_); 1 };
    my $err = $@;
    confess($err) unless $ok;
    $out;
}

sub encode_json {
    my $out;
    my $ok  = eval { $out = $ascii->encode(@_); 1 };
    my $err = $@;
    confess($err) unless $ok;
    $out;
}

sub encode_pretty_json {
    my $out;
    my $ok  = eval { $out = $pretty->encode(@_); 1 };
    my $err = $@;
    confess($err) unless $ok;
    $out;
}

sub json_true  { Cpanel::JSON::XS->true }
sub json_false { Cpanel::JSON::XS->false }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::JSON - JSON encoding/decoding utilities

=head1 DESCRIPTION

Provides JSON encode/decode utilities using L<Cpanel::JSON::XS>.

=head1 SYNOPSIS

    use Test2::Harness2::Util::JSON qw/encode_json decode_json encode_pretty_json json_true json_false/;

    my $json = encode_json({ foo => 'bar' });
    my $data = decode_json($json);
    my $pretty = encode_pretty_json({ foo => 'bar' });

=head1 EXPORTS

All exports are optional.

=over 4

=item encode_json($data)

Encode data structure to JSON. Output is ASCII-safe (non-ASCII characters are
escaped). Blessed objects are serialized via C<TO_JSON> if available.

=item decode_json($json)

Decode a JSON string to a Perl data structure.

=item encode_pretty_json($data)

Encode data structure to pretty-printed, canonically-ordered JSON.

=item json_true()

Returns a JSON boolean true value.

=item json_false()

Returns a JSON boolean false value.

=back

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

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
