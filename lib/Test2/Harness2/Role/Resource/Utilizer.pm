package Test2::Harness2::Role::Resource::Utilizer;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;

# Role::Tiny must mark this as a role before HashBase loads.
use Role::Tiny;
use Object::HashBase qw{
    &Test2::Harness2::Role::Resource
    <utilize_percent
    <min_concurrent
};

requires 'is_temporarily_unavailable';

sub set_utilize_percent {
    my ($self, $pct) = @_;
    $self->{+UTILIZE_PERCENT} = $self->_validate_utilize_percent($pct);
    return;
}

# Scheduler-level check. Reads the scheduler's shared in-flight count
# via the base role's in_flight() accessor. Defer only when saturated
# AND in-flight already meets the min_concurrent floor (default 1) --
# below the floor, at least min_concurrent tests are always allowed
# to run even if the subsystem never drops back below threshold.
sub should_defer_for_utilization {
    my $self = shift;
    my $min  = $self->{+MIN_CONCURRENT} // 1;
    return 0 if $self->in_flight < $min;
    return $self->is_temporarily_unavailable ? 1 : 0;
}

# Validate 0 < pct < 100. Returns the validated value.
sub _validate_utilize_percent {
    my ($self, $pct) = @_;

    croak ref($self) . "::set_utilize_percent requires a numeric percentage"
        unless defined $pct && $pct =~ m/^[0-9]+(?:\.[0-9]+)?\z/;

    croak ref($self) . "::set_utilize_percent percentage must be > 0 and < 100 (got '$pct')"
        unless $pct > 0 && $pct < 100;

    return $pct;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Role::Resource::Utilizer - Utilization-aware resource role.

=head1 DESCRIPTION

Layers utilization-aware behaviour on top of
L<Test2::Harness2::Role::Resource>. Consumers implement
C<is_temporarily_unavailable> (subsystem saturated?) and accept a
percentage threshold (C<0 E<lt> pct E<lt> 100>). The role provides
L</should_defer_for_utilization>, which adds a C<min_concurrent>
floor on top so the scheduler never starves.

Folds into the scheduler walk between C<is_usable> and C<available>
(see L<Test2::Harness2::Role::Resource>).

=head1 REQUIRED METHODS

=over 4

=item $bool = $resource->is_temporarily_unavailable

True when the resource's monitored subsystem is currently above the
configured threshold.

=back

=head1 PROVIDED METHODS

=over 4

=item $bool = $resource->should_defer_for_utilization

Scheduler hook. Returns true iff C<in_flight E<gt>= min_concurrent>
AND C<is_temporarily_unavailable> is true. Below the
C<min_concurrent> floor (default C<1>) saturation never defers, so
at least that many tests are always permitted to run.

=item $n = $resource->min_concurrent

Starvation-floor count. Default C<1>.

=item $pct = $resource->utilize_percent

Configured threshold percentage.

=item $resource->set_utilize_percent($pct)

Validate (C<0 E<lt> pct E<lt> 100>) and store. Override if the
resource must react to live changes (e.g. re-prime a sampler).

=back

=head1 SEE ALSO

L<Test2::Harness2::Role::Resource> -- base resource contract.

L<Test2::Harness2::Resource::Throttle> -- complementary spawn-rate
gate that pairs with the utilizer percentage threshold.

L<App::Yath2::Options::Resource> -- the C<--utilize> / C<-U> option.

=head1 SOURCE

L<https://github.com/Test-More/Test2-Harness>

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

See L<https://dev.perl.org/licenses/>

=cut
