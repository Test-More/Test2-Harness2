package Test2::Harness2::Resource::Disk::Threshold;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;

use Importer Importer => 'import';

our @EXPORT_OK = qw/parse_threshold evaluate_threshold/;

my %UNIT_MULT = (
    kb => 1024,
    mb => 1024**2,
    gb => 1024**3,
    tb => 1024**4,
);

sub parse_threshold {
    my ($raw) = @_;

    croak "threshold is required" unless defined $raw && length $raw;

    my $s = $raw;
    $s =~ s/\s+//g;

    my ($num, $unit) = $s =~ m/^([0-9]+(?:\.[0-9]+)?)(kb|mb|gb|tb|%)?\z/i
        or croak "invalid threshold '$raw' (expected NUMBER[kb|mb|gb|tb|%])";

    $unit = defined($unit) ? lc($unit) : '%';

    if ($unit eq '%') {
        croak "invalid threshold '$raw' (percent must be > 0 and < 100)"
            unless $num > 0 && $num < 100;
        return {kind => 'pct', value => $num + 0};
    }

    my $mult = $UNIT_MULT{$unit}
        or croak "invalid threshold '$raw' (unknown unit '$unit')";

    croak "invalid threshold '$raw' (byte threshold must be > 0)"
        unless $num > 0;

    return {kind => 'bytes', value => int($num * $mult)};
}

sub evaluate_threshold {
    my ($threshold, $free_bytes, $total_bytes) = @_;

    croak "evaluate_threshold requires a parsed threshold hashref"
        unless ref($threshold) eq 'HASH'
        && defined $threshold->{kind}
        && defined $threshold->{value};

    croak "evaluate_threshold requires non-negative free_bytes"
        unless defined $free_bytes && $free_bytes >= 0;

    if ($threshold->{kind} eq 'pct') {
        croak "evaluate_threshold requires positive total_bytes for pct threshold"
            unless defined $total_bytes && $total_bytes > 0;
        my $free_pct = ($free_bytes / $total_bytes) * 100;
        return $free_pct >= $threshold->{value} ? 'ok' : 'low';
    }

    return $free_bytes >= $threshold->{value} ? 'ok' : 'low'
        if $threshold->{kind} eq 'bytes';

    croak "evaluate_threshold: unknown threshold kind '$threshold->{kind}'";
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Resource::Disk::Threshold - Parse and evaluate disk free-space thresholds.

=head1 SYNOPSIS

    use Test2::Harness2::Resource::Disk::Threshold qw/parse_threshold evaluate_threshold/;

    my $t1 = parse_threshold('25%');     # { kind => 'pct',   value => 25 }
    my $t2 = parse_threshold('512mb');   # { kind => 'bytes', value => 536870912 }

    my $state = evaluate_threshold($t1, $free_bytes, $total_bytes);  # 'ok' or 'low'

=head1 EXPORTS

=over 4

=item $threshold = parse_threshold($string)

Parse a threshold string into a normalised hashref. Accepts:

    25         # 25% free required (default unit = %)
    25%        # 25% free required
    512kb      # 512 * 1024 free bytes required
    512mb      # 512 * 1024**2 free bytes required
    1gb        # 1   * 1024**3 free bytes required
    2tb        # 2   * 1024**4 free bytes required

Case-insensitive. Whitespace is stripped. Percent thresholds must satisfy
C<< 0 < pct < 100 >>; byte thresholds must be C<< > 0 >>. Invalid inputs croak.

=item $state = evaluate_threshold($threshold, $free_bytes, $total_bytes)

Compare a parsed threshold against a sample. Returns C<'ok'> when free
space meets or exceeds the threshold, C<'low'> otherwise. Croaks on
malformed arguments. C<$total_bytes> is required for percent thresholds.

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
