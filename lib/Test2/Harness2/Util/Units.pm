package Test2::Harness2::Util::Units;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;

use Importer Importer => 'import';

our @EXPORT_OK = qw/parse_quantity parse_byte_size parse_duration parse_count_or_pct parse_size_or_pct/;

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

sub parse_count_or_pct {
    my ($raw, %opts) = @_;
    my $name = $opts{name} // 'count';

    croak "$name is required" unless defined $raw && length $raw;

    # Bare non-negative integer = count (no fractional, no unit suffix).
    my $s = $raw;
    $s =~ s/\s+//g;
    if ($s =~ m/^[0-9]+\z/) {
        croak "invalid $name '$raw' (count must be > 0)" unless $s > 0;
        return {kind => 'count', value => $s + 0};
    }

    # Otherwise must be NUMBER%.
    my ($num, $unit) = parse_quantity(
        $raw,
        units        => [qw/%/],
        default_unit => undef,
        name         => $name,
    );

    croak "invalid $name '$raw' (expected NUMBER or NUMBER%)"
        unless defined $unit && $unit eq '%';

    croak "invalid $name '$raw' (pct must be > 0 and < 100)"
        unless $num > 0 && $num < 100;

    return {kind => 'pct', value => $num};
}

sub parse_size_or_pct {
    my ($raw, %opts) = @_;
    my $name    = $opts{name} // 'size';
    my $default = $opts{default_unit};

    croak "$name is required" unless defined $raw && length $raw;

    # With no default_unit, bare numbers (no kb/mb/gb/tb/% suffix) are
    # ambiguous; reject them with a clear message. With a default_unit
    # supplied the bare number is interpreted as that unit -- this is
    # the path used by callers like Resource::Disk where "25" means
    # "25%" and a leading-digit threshold is intentional shorthand.
    unless (defined $default) {
        my $s = $raw;
        $s =~ s/\s+//g;
        croak "invalid $name '$raw' (expected NUMBER[kb|mb|gb|tb|%])"
            if $s =~ m/^[0-9]+(?:\.[0-9]+)?\z/;
    }

    my ($num, $unit) = parse_quantity(
        $raw,
        units        => [qw/kb mb gb tb %/],
        default_unit => $default,
        name         => $name,
    );

    if ($unit eq '%') {
        croak "invalid $name '$raw' (pct must be > 0 and < 100)"
            unless $num > 0 && $num < 100;
        return {kind => 'pct', value => $num};
    }

    croak "invalid $name '$raw' (must be > 0)" unless $num > 0;

    my %mult = (
        kb => 1024,
        mb => 1024**2,
        gb => 1024**3,
        tb => 1024**4,
    );

    return {kind => 'bytes', value => int($num * $mult{$unit})};
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::Units - Parse number-with-unit strings used by yath options.

=head1 SYNOPSIS

    use Test2::Harness2::Util::Units qw/parse_quantity parse_byte_size parse_duration parse_count_or_pct parse_size_or_pct/;

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

=item $result = parse_count_or_pct($raw, %opts)

Domain helper. Accepts either a bare positive integer (count) or a
C<NUMBER%> string (percent, exclusive of 0 and 100). Returns a hashref
with keys C<kind> (C<'count'> or C<'pct'>) and C<value> (numeric).
Fractional counts are rejected. Optional C<name> defaults to C<'count'>.

=item $result = parse_size_or_pct($raw, %opts)

Domain helper. Accepts either a byte-size string with a
C<kb>/C<mb>/C<gb>/C<tb> suffix or a C<NUMBER%> string (percent,
exclusive of 0 and 100). Returns a hashref with keys C<kind>
(C<'bytes'> or C<'pct'>) and C<value> (integer bytes, or numeric
percent). Optional C<name> defaults to C<'size'>.

Bare numbers without a unit are rejected unless an explicit
C<default_unit> option is supplied; when present, a bare number is
interpreted as that unit. Example: a disk-free threshold that
defaults to percent passes C<< default_unit =E<gt> '%' >> so
C<parse_size_or_pct('25')> returns C<< { kind => 'pct', value => 25 } >>.

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
