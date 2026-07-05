package Test2::Harness2::Util::Units;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;

use Importer Importer => 'import';

our @EXPORT_OK = qw/parse_quantity parse_byte_size parse_size_or_pct parse_count_or_pct parse_duration/;

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::Units - Parse number-with-unit strings used by yath options.

=head1 DESCRIPTION

Small parsing helpers for the C<NUMBER[unit]> strings yath options accept (byte
sizes, percentages). Used by the throttling resources to interpret a memory
threshold expressed either as a percentage of total memory or an absolute byte
size.

=head1 SYNOPSIS

    use Test2::Harness2::Util::Units qw/parse_byte_size parse_size_or_pct parse_count_or_pct parse_duration/;

    my $bytes = parse_byte_size('1gb');             # 1073741824
    my $spec  = parse_size_or_pct('20%');           # { kind => 'pct',   value => 20 }
    my $spec  = parse_size_or_pct('512mb');         # { kind => 'bytes', value => 536870912 }
    my $spec  = parse_count_or_pct('5');            # { kind => 'count', value => 5 }
    my $spec  = parse_count_or_pct('50%');          # { kind => 'pct',   value => 50 }
    my $secs  = parse_duration('500ms');            # 0.5
    my $secs  = parse_duration('2');                # 2 (default unit = 's')

=head1 EXPORTS

=cut

=over 4

=item ($num, $unit) = parse_quantity($raw, %opts)

Low-level primitive: split C<$raw> into a numeric value and a unit suffix taken
from C<< units => [...] >>. The match is case-insensitive and the returned unit
is lowercased. With C<< default_unit => '...' >> a bare number with no unit is
accepted and assigned that unit; without it a bare number croaks. C<name> is used
in error messages (defaults to C<'value'>).

=cut

sub parse_quantity ($raw, %opts) {
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

=item $bytes = parse_byte_size($raw, %opts)

Accept a C<kb>/C<mb>/C<gb>/C<tb> suffix (case-insensitive) and return integer
bytes. C<default_unit> defaults to none (a unit is required); C<name> defaults to
C<'size'>.

=cut

sub parse_byte_size ($raw, %opts) {
    my ($num, $unit) = parse_quantity(
        $raw,
        units        => [qw/kb mb gb tb/],
        default_unit => $opts{default_unit},
        name         => $opts{name} // 'size',
    );

    croak "invalid " . ($opts{name} // 'size') . " '$raw' (must be > 0)"
        unless $num > 0;

    return int($num * _byte_mult($unit));
}

=item $result = parse_size_or_pct($raw, %opts)

Accept either a byte-size string (C<kb>/C<mb>/C<gb>/C<tb> suffix) or a C<NUMBER%>
string (percent, exclusive of 0 and 100). Return a hashref C<< {kind, value} >>
where C<kind> is C<'bytes'> (C<value> = integer bytes) or C<'pct'> (C<value> =
numeric percent). A bare number with no unit is rejected unless C<default_unit> is
supplied. C<name> defaults to C<'size'>.

=cut

sub parse_size_or_pct ($raw, %opts) {
    my $name    = $opts{name} // 'size';
    my $default = $opts{default_unit};

    croak "$name is required" unless defined $raw && length $raw;

    # Reject ambiguous bare numbers unless the caller supplied a default_unit.
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

    return {kind => 'bytes', value => int($num * _byte_mult($unit))};
}

=item $result = parse_count_or_pct($raw, %opts)

Accept either a bare positive integer (a count) or a C<NUMBER%> string
(percent, exclusive of 0 and 100). Return a hashref C<< {kind, value} >> where
C<kind> is C<'count'> (C<value> = integer count) or C<'pct'> (C<value> = numeric
percent). Fractional counts are rejected. Builds on L</parse_quantity> for the
percent case. C<name> defaults to C<'count'>.

=cut

sub parse_count_or_pct ($raw, %opts) {
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

=item $secs = parse_duration($raw, %opts)

General duration parser: accept a C<ms>/C<s>/C<m> suffix (case-insensitive) and
return float seconds. C<default_unit> defaults to C<'s'> (a bare number is
treated as seconds); C<name> defaults to C<'duration'>.

Intended for B<timeout> values (e.g. C<timeout.event>/C<timeout.postexit> →
seconds). It is B<not> for the C<duration short|medium|long> scheduling
directive, which stays a scheduling label and is never parsed as seconds.

=cut

sub parse_duration ($raw, %opts) {
    my ($num, $unit) = parse_quantity(
        $raw,
        units        => [qw/ms s m/],
        default_unit => $opts{default_unit} // 's',
        name         => $opts{name}         // 'duration',
    );

    croak "invalid " . ($opts{name} // 'duration') . " '$raw' (must be > 0)"
        unless $num > 0;

    state $mult = {
        ms => 0.001,
        s  => 1,
        m  => 60,
    };

    return $num * $mult->{$unit};
}

# Bytes-per-unit for the byte-size suffixes (helper, not exported).
sub _byte_mult ($unit) {
    state $mult = {
        kb => 1024,
        mb => 1024**2,
        gb => 1024**3,
        tb => 1024**4,
    };
    return $mult->{$unit} // croak "unknown byte unit '$unit'";
}

1;

__END__

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness2/>.

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

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
