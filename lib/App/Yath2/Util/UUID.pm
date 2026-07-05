package App::Yath2::Util::UUID;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Test2::Util::UUID();

use Importer 'Importer' => 'import';

our @EXPORT    = qw/gen_uuid derive_uuid/;
our @EXPORT_OK = qw/gen_uuid derive_uuid/;

# Test2::Util::UUID builds gen_uuid() dynamically (no callable
# Test2::Util::UUID::gen_uuid symbol exists), so fetch the coderef once and wrap
# it. Boundary normalization (R9): the backend mints uppercase UUIDs via
# Test2::Util::UUID; the DB layer's canonical form is lowercase. Centralize the
# lowercasing here so there are no scattered lc() calls at comparison sites.
my $T2_GEN_UUID = Test2::Util::UUID->get_gen_uuid->{gen_uuid}
    or croak "Test2::Util::UUID did not provide a gen_uuid backend";

sub gen_uuid { return lc($T2_GEN_UUID->()) }

#
# derive_uuid($base_uuid, $offset) -- v7-preserving derived UUID (spec §3.1 / R4).
#
# A v7 UUID is 16 bytes / 128 bits, big-endian, laid out (MSB -> LSB) as:
#
#   byte:  0    1    2    3    4    5     6        7      8        9 ... 15
#         +----+----+----+----+----+----+--------+------+--------+-----------+
#         | 48-bit unix_ts_ms            | ver|ra| rand_a| var|rb | rand_b    |
#         +----+----+----+----+----+----+--------+------+--------+-----------+
#
#   [ 48 bits unix_ts_ms ][ 4 bits version=0111 ][ 12 bits rand_a ]
#   [ 2 bits variant=10 ][ 62 bits rand_b ]
#
#   - bytes 0..5            : unix_ts_ms (48 bits)
#   - byte 6, high nibble   : version  = 0b0111 (7)
#   - byte 6 low nibble + 7 : rand_a   (12 bits)
#   - byte 8, top 2 bits    : variant  = 0b10
#   - byte 8 low 6 bits + 9..15 : rand_b (62 bits) == the LOW 62 bits of the int
#
# derive: rand_b' = (rand_b + offset) mod 2^62 -- add-with-wrap. The carry NEVER
# leaves the 62-bit rand_b field, so the timestamp, version, rand_a, and variant
# bits above it are preserved byte-for-byte and the result is still a valid v7
# UUID. We operate only on the low 8 bytes (bytes 8..15 = 64 bits): add the
# offset there, then mask the result to 62 bits, which both performs the mod-2^62
# wrap and restores the variant bits (the top 2 bits of byte 8) from the original.
#
# 64-bit math is done as two 32-bit halves with an explicit carry so this is safe
# regardless of the platform's native integer size (no reliance on 64-bit IVs).
#
sub derive_uuid {
    my ($base_uuid, $offset) = @_;

    croak "A base UUID is required"             unless defined $base_uuid;
    croak "An offset is required"               unless defined $offset;
    croak "Offset must be a non-negative integer"
        unless $offset =~ /^\d+$/;

    # Canonical 36-char string -> 16 raw bytes.
    (my $hex = $base_uuid) =~ s/-//g;
    croak "'$base_uuid' does not look like a UUID"
        unless length($hex) == 32 && $hex =~ /^[0-9a-fA-F]{32}$/;
    my $bytes = pack('H*', $hex);

    # Split into the high 8 bytes (untouched) and the low 8 bytes (rand_b lives
    # in the bottom 62 of these). Unpack the low 8 bytes as two big-endian
    # 32-bit halves.
    my $high = substr($bytes, 0, 8);
    my ($lo_hi, $lo_lo) = unpack('N N', substr($bytes, 8, 8));

    # Add the offset into the 64-bit low half with carry between the 32-bit words.
    # Use modular arithmetic on the low word so we never form an integer wider
    # than 2^32 in the addition itself.
    my $off = $offset + 0;                 # numify
    my $add_lo = $off % 4294967296;        # 2^32
    my $add_hi = int($off / 4294967296);

    my $new_lo = $lo_lo + $add_lo;
    my $carry  = $new_lo >= 4294967296 ? 1 : 0;
    $new_lo %= 4294967296;

    my $new_hi = ($lo_hi + $add_hi + $carry) % 4294967296;

    # Mask the combined 64-bit value down to 62 bits: this implements the
    # mod-2^62 wrap AND clears the top 2 bits of byte 8 (the high half), which we
    # then OR back from the original so the variant bits are preserved exactly.
    # Top 2 bits of the 64-bit value live in bit 31..30 of $new_hi.
    my $variant_bits = $lo_hi & 0xC0000000;    # original top 2 bits (variant)
    $new_hi &= 0x3FFFFFFF;                      # keep low 30 bits of the high word
    $new_hi |= $variant_bits;                   # restore variant

    my $low = pack('N N', $new_hi, $new_lo);

    my $out_hex = unpack('H*', $high . $low);
    $out_hex = lc($out_hex);

    return join '-', (
        substr($out_hex,  0, 8),
        substr($out_hex,  8, 4),
        substr($out_hex, 12, 4),
        substr($out_hex, 16, 4),
        substr($out_hex, 20, 12),
    );
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Util::UUID - Central UUID source + v7-preserving derived UUIDs for the DB layer.

=head1 DESCRIPTION

This module is the single boundary for UUIDs in the App::Yath2 DB layer. It
exports a C<gen_uuid()> that returns B<lowercase> (the DB layer's canonical
form) and a C<derive_uuid()> that deterministically derives a child UUID from a
base v7 UUID while preserving the v7 version/variant/timestamp bits.

=head1 SYNOPSIS

    use App::Yath2::Util::UUID qw/gen_uuid derive_uuid/;

    my $uuid     = gen_uuid();                  # lowercase v7
    my $try_uuid = derive_uuid($job_uuid, 1);   # job's first try

=head1 EXPORTS

=over 4

=item $uuid = gen_uuid()

Generate a UUID via L<Test2::Util::UUID> and return it normalized to B<lower
case> (R9 boundary normalization). The backend mints uppercase UUIDs; the DB
layer is lowercase-canonical, so all generation routes through here.

=item $derived = derive_uuid($base_uuid, $offset)

Deterministically derive a UUID from a base B<v7> UUID and a non-negative
integer C<$offset>, per spec §3.1. The base is treated as a 128-bit big-endian
unsigned integer; C<rand_b> (the low 62 bits) becomes
C<< (rand_b + offset) mod 2^62 >> (add-with-wrap). The carry never leaves the
62-bit C<rand_b> field, so the timestamp, version, C<rand_a>, and variant bits
are preserved byte-for-byte and the result is still a valid v7 UUID. The
returned string is canonical lowercase.

Properties: deterministic (same base+offset -> same result on every host);
C<offset == 0> returns the base unchanged; C<< offset >= 1 >> never collides
with the base; distinct offsets in C<[0, 2^62)> give distinct results.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness2/>.

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

See F<http://dev.perl.org/licenses/>

=cut
