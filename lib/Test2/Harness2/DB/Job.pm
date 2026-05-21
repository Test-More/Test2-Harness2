package Test2::Harness2::DB::Job;
use strict;
use warnings;

our $VERSION = '2.000000';

use Object::HashBase qw{
    &Test2::Harness2::Role::Row
    <job_id
    <run_id
    <test_file_id
    <spec
};
sub TABLE        { 'jobs' }
sub PRIMARY_KEY  { 'job_id' }
sub COLUMNS      { qw/job_id run_id test_file_id spec/ }
sub JSON_COLUMNS { qw/spec/ }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::DB::Job - Row object for the C<jobs> table.

=head1 DESCRIPTION

One row per scheduled job under a run. C<spec> is the JSON launch
spec (env, args, directives, retry policy, etc.).

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
