package Test2::Harness2::Collector::Service::Run;
use strict;
use warnings;

our $VERSION = '2.000011';

use parent 'Test2::Harness2::Collector::Service';

# A run-service collector identifies its loggers with is_run => 1 so
# the role's output_file_basename rules collapse the common-case
# service_name == run_id path down to $logdir/runs/<run_id>, which
# is where the run's .jsonl and .json belong. Callers that build
# this subclass directly rarely want a different value, so default
# IS_RUN to 1 in init and let the rare override still come through.
sub init {
    my $self = shift;
    $self->{+Test2::Harness2::Collector::IS_RUN()} //= 1;
    return $self->SUPER::init(@_);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Service::Run - Interpose collector subclass for the run service.

=head1 DESCRIPTION

Marks its loggers as belonging to a run-service collector so the
role's path derivation selects the C<$logdir/runs/E<lt>run_idE<gt>>
layout (the I<run's collector> special case) rather than placing
the run's own .jsonl and .json under C<runs/E<lt>run_idE<gt>/services/>
alongside resource services scoped to the run.

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
