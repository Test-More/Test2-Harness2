package Test2::Harness2::Util::Units;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;

use Importer Importer => 'import';

our @EXPORT_OK = qw/parse_quantity parse_byte_size parse_duration/;

sub parse_quantity {
    my ($raw, %opts) = @_;

    my $units   = $opts{units} or croak "parse_quantity: 'units' arrayref is required";
    my $default = $opts{default_unit};
    my $name    = $opts{name} // 'value';

    croak "$name is required" unless defined $raw && length $raw;

    my $s = $raw;
    $s =~ s/\s+//g;

    my $alt = join '|', map { quotemeta $_ } @$units;

    my ($num, $unit) = $s =~ m/^([0-9]+(?:\.[0-9]+)?)($alt)?\z/i
        or croak "invalid $name '$raw' (expected NUMBER[" . join('|', @$units) . "])";

    if (defined $unit) {
        $unit = lc $unit;
    }
    else {
        croak "invalid $name '$raw' (unit required: one of " . join(', ', @$units) . ")"
            unless defined $default;
        $unit = $default;
    }

    return ($num + 0, $unit);
}

sub parse_byte_size {
    my ($raw, %opts) = @_;

    my ($num, $unit) = parse_quantity(
        $raw,
        units        => [qw/kb mb gb tb/],
        default_unit => $opts{default_unit},
        name         => $opts{name} // 'size',
    );

    croak "invalid " . ($opts{name} // 'size') . " '$raw' (must be > 0)"
        unless $num > 0;

    my %mult = (
        kb => 1024,
        mb => 1024**2,
        gb => 1024**3,
        tb => 1024**4,
    );

    return int($num * $mult{$unit});
}

sub parse_duration {
    my ($raw, %opts) = @_;

    my ($num, $unit) = parse_quantity(
        $raw,
        units        => [qw/ms s m/],
        default_unit => $opts{default_unit} // 's',
        name         => $opts{name}         // 'duration',
    );

    croak "invalid " . ($opts{name} // 'duration') . " '$raw' (must be > 0)"
        unless $num > 0;

    my %mult = (
        ms => 0.001,
        s  => 1,
        m  => 60,
    );

    return $num * $mult{$unit};
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::Units - Parse number-with-unit strings used by yath options.

=head1 SYNOPSIS

    use Test2::Harness2::Util::Units qw/parse_quantity parse_byte_size parse_duration/;

    my ($n, $u) = parse_quantity('512mb', units => [qw/kb mb gb tb/]);
    # ($n, $u) = (512, 'mb')

    my $bytes = parse_byte_size('1gb');         # 1073741824
    my $secs  = parse_duration('500ms');        # 0.5
    my $secs  = parse_duration('2');            # 2 (default unit = 's')

=head1 EXPORTS

=over 4

=item ($num, $unit) = parse_quantity($raw, %opts)

Low-level primitive. Splits C<$raw> into a numeric value and a unit
suffix from a caller-supplied set.

C<%opts>:

=over 4

=item units => [...]

(required) Arrayref of accepted unit suffixes. Lowercase. The match is
case-insensitive and the returned unit is lowercased.

=item default_unit => '...'

Optional. If set, a bare number with no unit is accepted and the
returned unit is this value. If absent, a bare number croaks.

=item name => '...'

Optional. Used in error messages. Defaults to C<'value'>.

=back

Whitespace is stripped from C<$raw>. Negative numbers and numbers with
unrecognised unit suffixes croak.

=item $bytes = parse_byte_size($raw, %opts)

Domain helper. Accepts C<kb>/C<mb>/C<gb>/C<tb> suffixes
(case-insensitive). Returns integer bytes. Optional C<default_unit>
defaults to none (unit required). Optional C<name> defaults to
C<'size'>.

=item $secs = parse_duration($raw, %opts)

Domain helper. Accepts C<ms>/C<s>/C<m> suffixes (case-insensitive).
Returns float seconds. Optional C<default_unit> defaults to C<'s'>.
Optional C<name> defaults to C<'duration'>.

=back

=head1 SOURCE

L<https://github.com/Test-More/Test2-Harness>

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

See L<https://dev.perl.org/licenses/>

=cut
