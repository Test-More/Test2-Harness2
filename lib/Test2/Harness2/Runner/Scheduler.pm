package Test2::Harness2::Runner::Scheduler;
use strict;
use warnings;

our $VERSION = '2.000000';

use Object::HashBase qw{
    +_handle
    <scheduler_id
    <runner_id
    <class
    <spec
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Row';

sub TABLE        { 'schedulers' }
sub PRIMARY_KEY  { 'scheduler_id' }
sub COLUMNS      { qw/scheduler_id runner_id class spec/ }
sub JSON_COLUMNS { qw/spec/ }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::Scheduler - Row object for the C<schedulers>
table.

=head1 DESCRIPTION

One row per runner. C<class> is the Perl class implementing the
scheduler; C<spec> is the JSON construction spec (queue policy,
concurrency caps, resource bindings, etc.).

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
