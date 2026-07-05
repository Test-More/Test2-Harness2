package Test2::Harness2::Role::Resource::Utilizer;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Time::HiRes qw/time/;

# Role::Tiny must mark this as a role before HashBase loads.
use Role::Tiny;

# Compose the base resource contract. A throttle resource (CPU/Memory/UnixLimits)
# composes ONLY this role and still IS-A Test2::Harness2::Runner::Resource; the
# shared available/assign/record/release below satisfy and override the base
# contract in one place.
with 'Test2::Harness2::Runner::Resource';

use Test2::Harness2::Util::HashBase qw{
    <utilize_percent
    <min_concurrent
    +in_flight_jobs
};

requires 'is_temporarily_unavailable', 'settings';

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Role::Resource::Utilizer - Utilization-aware throttling for a
resource.

=head1 DESCRIPTION

Layers utilization-aware deferral on top of L<Test2::Harness2::Runner::Resource>.
A consuming resource implements C<is_temporarily_unavailable> (is the monitored
subsystem -- CPU, memory, ... -- currently saturated?), and this role decides
whether to defer a new test start: it defers B<only> when the subsystem is
saturated B<and> at least C<min_concurrent> tests are already in flight, so at
least that many tests always run even under sustained saturation (the scheduler
never stalls).

The consumer tracks its own in-flight count through this role's C<track_started>
/ C<track_released> helpers (call them from the resource's C<record> / C<release>
hooks), and asks C<should_defer_for_utilization> from C<available>.

This is a deferral (a transient "wait"), never a permanent skip: when saturated,
C<available> returns C<0>, not C<-1>.

=head1 ATTRIBUTES

=over 4

=item utilize_percent

The saturation threshold percentage the consuming resource gates on.

=item min_concurrent

The starvation floor: deferral only kicks in once at least this many tests are in
flight. Defaults to 1.

=back

=head1 PROVIDED METHODS

=cut

=over 4

=item $n = $self->in_flight

The number of tests this resource currently counts as in flight.

=item $self->track_started($job_id)

=item $self->track_released($job_id)

Maintain the in-flight set. Call C<track_started> from the resource's C<record>
hook and C<track_released> from its C<release> hook.

=item $bool = $self->should_defer_for_utilization

True when C<in_flight E<gt>= min_concurrent> B<and> C<is_temporarily_unavailable>
is true. Below the floor, saturation never defers.

=item $bool = $self->is_supported

Whether the monitored subsystem can be read on this host. Defaults to true; a
consumer that can deactivate (e.g. UnixLimits with no C</proc>) overrides it, and
C<available> then short-circuits to "available" (no throttling).

=item $val = $self->available(\%task)

C<0> to defer (saturated and the starvation floor is met), otherwise C<1>. Returns
C<1> unconditionally on an unsupported host. Croaks if C<$task> is undef.

=item $self->assign(\%task, \%state)

Stamps C<< $state->{record} >> so the job is tracked; assigns no env/args.

=item $self->record($job_id, $info)

=item $self->release($job_id)

Maintain the in-flight set via C<track_started> / C<track_released>.

=back

=cut

sub in_flight ($self) { return scalar keys %{$self->{+IN_FLIGHT_JOBS} //= {}} }

sub track_started ($self, $job_id) {
    ($self->{+IN_FLIGHT_JOBS} //= {})->{$job_id} = 1;
    return;
}

sub track_released ($self, $job_id) {
    delete $self->{+IN_FLIGHT_JOBS}{$job_id} if $self->{+IN_FLIGHT_JOBS};
    return;
}

# Scheduler-level check. Defer only when saturated AND in-flight already meets the
# min_concurrent floor (default 1) -- below the floor at least min_concurrent tests
# are always allowed to run even if the subsystem never drops below threshold.
sub should_defer_for_utilization ($self) {
    my $min = $self->{+MIN_CONCURRENT} // 1;
    return 0 if $self->in_flight < $min;
    return $self->is_temporarily_unavailable ? 1 : 0;
}

# --- Shared resource contract for the throttle resources --------------------
# CPU/Memory/UnixLimits differ only in is_temporarily_unavailable / is_supported;
# the scheduler-facing contract is identical, so it lives here once.

# Overridable gate: a resource that can deactivate (UnixLimits without /proc)
# overrides this; the default is "always supported".
sub is_supported { 1 }

sub available ($self, $task = undef) {
    croak "a task is required" unless defined $task;
    return 1 unless $self->is_supported;
    return $self->should_defer_for_utilization ? 0 : 1;
}

sub assign ($self, $task, $state) {
    $state->{record} = {job_id => $task->{job_id}, stamp => time};
    return;
}

sub record ($self, $job_id, $info = undef) {
    $self->track_started($job_id);
    return;
}

sub release ($self, $job_id) {
    $self->track_released($job_id);
    return;
}

# The --utilize percentage from settings, or undef when none was given.
sub _utilize_from_settings ($self) {
    my $settings = $self->settings or return undef;
    return undef unless $settings->check_group('runner');
    my $runner = $settings->runner;
    return undef unless $runner->check_option('utilize');
    return $runner->utilize;
}

1;

__END__

=head1 SEE ALSO

L<Test2::Harness2::Runner::Resource> -- the base resource contract.

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
