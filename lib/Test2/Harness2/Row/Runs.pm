package Test2::Harness2::Row::Runs;
use strict;
use warnings;

our $VERSION = '2.000000';

use parent 'Test2::Harness2::Row';
use Object::HashBase qw{
    <run_id
    <run_uuid
    <runner_id
    <project_id
    <version_id
    <user_id
    <run_ord
    <started
    <finished
    <result
    <passed
    <failed
    <meta
    <abort
};

sub TABLE        { 'runs' }
sub PRIMARY_KEY  { 'run_id' }
sub COLUMNS      {
    qw/run_id run_uuid runner_id project_id version_id user_id run_ord
       started finished result passed failed meta abort/
}
sub JSON_COLUMNS { qw/meta/ }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Row::Runs - Row object for the C<runs> table.

=head1 DESCRIPTION

One row per run. C<meta> is JSON. C<result> is a tri-state boolean
(null = in flight, true = all jobs passed, false = at least one
failed). C<abort> asks the scheduler to terminate in-flight jobs.

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
