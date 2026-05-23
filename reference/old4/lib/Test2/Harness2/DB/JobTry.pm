package Test2::Harness2::DB::JobTry;
use strict;
use warnings;

our $VERSION = '2.000000';

use Object::HashBase qw{
    &Test2::Harness2::Role::Row
    <job_try_id
    <job_id
    <try_ord
    <started
    <finished
    <collector_id
    <result
    <passed
    <failed
    <subtests
    <subtests_passed
    <subtests_failed
    <status
};
sub TABLE       { 'job_tries' }
sub PRIMARY_KEY { 'job_try_id' }
sub COLUMNS     {
    qw/job_try_id job_id try_ord started finished collector_id result passed failed
       subtests subtests_passed subtests_failed status/
}

sub init {
    my $self = shift;
    $self->{+STATUS}          //= 'pending';
    $self->{+PASSED}          //= 0;
    $self->{+FAILED}          //= 0;
    $self->{+SUBTESTS}        //= 0;
    $self->{+SUBTESTS_PASSED} //= 0;
    $self->{+SUBTESTS_FAILED} //= 0;
    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::DB::JobTry - Row object for the C<job_tries> table.

=head1 DESCRIPTION

One row per attempt at running a job. C<try_ord> starts at 1.
C<result> is a tri-state boolean (null = in flight, true = pass,
false = fail).

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
