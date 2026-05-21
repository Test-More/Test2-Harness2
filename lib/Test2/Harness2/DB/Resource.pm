package Test2::Harness2::DB::Resource;
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

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::DB::Resource - Row object for the C<resources> table.

=head1 DESCRIPTION

One row per resource declared on a runner. The C<class> column carries
the Perl class implementing the resource; C<spec> is the JSON
construction spec. Resources can be runner-global (C<run_id> NULL) or
attached to a specific run (C<run_id> set).

Both halves are the same row class. The runner-global / run-scoped
distinction lives in the logic layer (L<Test2::Harness2::Runner::Resource>
and L<Test2::Harness2::Runner::Run::Resource>, to be authored when
the scheduler / launcher work lands).

Resource samples / telemetry live in the C<resource_snapshots>
table — see L<Test2::Harness2::DB::ResourceSnapshot>.

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
