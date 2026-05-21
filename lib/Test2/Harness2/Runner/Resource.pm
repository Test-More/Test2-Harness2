package Test2::Harness2::Runner::Resource;
use strict;
use warnings;

our $VERSION = '2.000000';

use Object::HashBase qw{
    &Test2::Harness2::Role::Row
    <resource_id
    <runner_id
    <run_id
    <class
    <spec
};
sub TABLE        { 'resources' }
sub PRIMARY_KEY  { 'resource_id' }
sub COLUMNS      { qw/resource_id runner_id run_id class spec/ }
sub JSON_COLUMNS { qw/spec/ }

sub class_for_row {
    my ($class, $row) = @_;
    return defined($row->{run_id})
        ? 'Test2::Harness2::Runner::Run::Resource'
        : 'Test2::Harness2::Runner::Resource';
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::Resource - Row object for the C<resources> table
(runner-global resources; dispatch base for run-scoped subclass).

=head1 DESCRIPTION

One row per resource declared on a runner. The C<class> column carries
the Perl class implementing the resource; C<spec> is the JSON
construction spec. Resources can be runner-global (C<run_id> NULL) or
attached to a specific run (C<run_id> set).

This class backs runner-global rows. Rows with a non-null C<run_id>
load as the subclass L<Test2::Harness2::Runner::Run::Resource> via
L</class_for_row>, so callers can branch on row class.

Resource samples / telemetry live in the C<resource_snapshots>
table — see L<Test2::Harness2::Runner::Resource::Snapshot>.

=head1 METHODS

=over 4

=item $real_class = $class->class_for_row(\%data)

Picks L<Test2::Harness2::Runner::Run::Resource> when C<\%data> has
a defined C<run_id>, otherwise returns this class.

=back

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

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
