package Test2::Harness2::Util::JSON;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/confess croak/;
use Cpanel::JSON::XS();
use File::Temp qw/tempfile/;
use Importer Importer => 'import';

use Test2::Harness2::Util qw/read_file write_file_atomic/;

our @EXPORT_OK = qw{
    decode_json
    decode_json_file
    decode_json_no_null
    decode_json_zst_file
    encode_json
    encode_json_file
    encode_pretty_json
    json_false
    json_true
    write_json_file_atomic
    write_json_zst_file_atomic
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::JSON - Thin JSON helpers used across the harness.

=head1 DESCRIPTION

Wraps L<Cpanel::JSON::XS> with the encoder/decoder configurations the
harness relies on: a UTF-8 decoder, an ASCII-safe encoder for messages
that travel through plain handles, and a pretty/canonical encoder for
human-facing files. Also provides convenience helpers for reading and
writing whole JSON files, including zstd-compressed variants.

=head1 SYNOPSIS

    use Test2::Harness2::Util::JSON qw/encode_json decode_json/;

    my $json = encode_json({ ... });
    my $data = decode_json($json);

    use Test2::Harness2::Util::JSON qw/encode_json_file decode_json_file/;
    my $path = encode_json_file({ ... });           # writes to a tempfile
    my $data = decode_json_file($path, unlink => 1);

=head1 EXPORTS

All exports are optional and must be requested explicitly.

=cut

my $json   = Cpanel::JSON::XS->new->utf8(1)->convert_blessed(1)->allow_nonref(1);
my $ascii  = Cpanel::JSON::XS->new->ascii(1)->convert_blessed(1)->allow_nonref(1);
my $pretty = Cpanel::JSON::XS->new->ascii(1)->pretty(1)->canonical(1)->convert_blessed(1)->allow_nonref(1);

=over 4

=item json_true

=item $bool = json_true()

=item json_false

=item $bool = json_false()

The canonical L<Cpanel::JSON::XS> boolean values, useful when building
structures destined for L</encode_json>.

=back

=cut

sub json_true  { Cpanel::JSON::XS->true }
sub json_false { Cpanel::JSON::XS->false }

=over 4

=item decode_json

=item $data = decode_json($json)

Decode UTF-8 JSON text. Confesses on decoding errors.

=back

=cut

sub decode_json {
    my $out;
    confess($@) unless eval { $out = $json->decode(@_); 1 };
    $out;
}

=over 4

=item encode_json

=item $json = encode_json($data)

Encode C<$data> to ASCII-safe JSON. Confesses on encoding errors.

=back

=cut

sub encode_json {
    my $out;
    confess($@) unless eval { $out = $ascii->encode(@_); 1 };
    $out;
}

=over 4

=item encode_pretty_json

=item $json = encode_pretty_json($data)

Encode C<$data> to ASCII-safe, pretty-printed, canonical (sorted-key)
JSON, suitable for files a human will read. Confesses on encoding
errors.

=back

=cut

sub encode_pretty_json {
    my $out;
    confess($@) unless eval { $out = $pretty->encode(@_); 1 };
    $out;
}

=over 4

=item decode_json_file

=item $data = decode_json_file($path, %params)

Slurp C<$path>, decode it via L</decode_json>, and return the result.
With C<unlink => 1> the file is removed after reading (a warn fires
if the unlink fails).

=back

=cut

sub decode_json_file {
    my ($file, %params) = @_;

    my $json_text = read_file($file);

    if ($params{unlink}) {
        unlink($file) or warn "Could not unlink '$file': $!";
    }

    return decode_json($json_text);
}

=over 4

=item encode_json_file

=item $path = encode_json_file($data)

Encode C<$data> with L</encode_json> and write it to a freshly-created
tempfile in the system tempdir (no C<UNLINK> -- the caller owns
cleanup). Returns the path.

=back

=cut

sub encode_json_file {
    my ($data) = @_;
    my $json_text = encode_json($data);

    my ($fh, $file) = tempfile("$$-XXXXXX", TMPDIR => 1, SUFFIX => '.json', UNLINK => 0);
    print $fh $json_text;
    close($fh);

    return $file;
}

=over 4

=item write_json_file_atomic

=item write_json_file_atomic($path, \%data)

Encode C<\%data> with L</encode_pretty_json> and write it to C<$path>
atomically via L<Test2::Harness2::Util/write_file_atomic>.

=back

=cut

sub write_json_file_atomic {
    my ($path, $data) = @_;

    croak "path is required"         unless defined $path;
    croak "data hashref is required" unless defined $data;

    write_file_atomic($path, encode_pretty_json($data));
    return;
}

=over 4

=item write_json_zst_file_atomic

=item write_json_zst_file_atomic($path, \%data)

Same as L</write_json_file_atomic>, but the encoded JSON is compressed
with zstd before the atomic rename. Used for snapshot files written
under conventions like C<.json.zst>.

=back

=cut

sub write_json_zst_file_atomic {
    my ($path, $data) = @_;

    croak "path is required"         unless defined $path;
    croak "data hashref is required" unless defined $data;

    require Test2::Harness2::Util::Zstd;
    Test2::Harness2::Util::Zstd::compress_file_atomic(
        $path,
        encode_pretty_json($data),
    );
    return;
}

=over 4

=item decode_json_zst_file

=item $data = decode_json_zst_file($path, %opts)

Read C<$path> as a zstd-compressed JSON file, decode it, and return
the result. C<unlink => 1> removes the file after reading.

=back

=cut

sub decode_json_zst_file {
    my ($file, %opts) = @_;

    croak "file is required" unless defined $file;

    require Test2::Harness2::Util::Zstd;
    my $bytes = Test2::Harness2::Util::Zstd::decompress_file($file);

    if ($opts{unlink}) {
        unlink($file) or warn "Could not unlink '$file': $!";
    }

    return decode_json($bytes);
}

=over 4

=item decode_json_no_null

=item $data = decode_json_no_null($json)

Decode C<$json> after first rewriting every unescaped C<\0> /
C<\u0000> to its escaped form. Lets producers that emit raw nulls
still be consumed. Dies on any underlying decode failure.

=back

=cut

sub decode_json_no_null {
    my ($input) = @_;

    my $escaped = $input;
    $escaped =~ s/(?<!\\)((?:\\)(?:0|u0000))/\\$1/g;

    my $out;
    my $ok  = eval { $out = decode_json($escaped); 1 };
    my $err = $@;
    die "decode_json_no_null: $err" unless $ok;
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
