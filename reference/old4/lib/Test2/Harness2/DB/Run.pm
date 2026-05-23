package Test2::Harness2::DB::Run;
use strict;
use warnings;

our $VERSION = '2.000000';

use Object::HashBase qw{
    &Test2::Harness2::Role::Row
    <run_id
    <run_uuid
    <runner_id
    <project_id
    <version_id
    <vcs_info_id
    <user_id
    <run_ord
    <started
    <finished
    <result
    <passed
    <failed
    <meta
    <status
    <has_coverage
    <has_resources
};
sub TABLE        { 'runs' }
sub PRIMARY_KEY  { 'run_id' }
sub COLUMNS      {
    qw/run_id run_uuid runner_id project_id version_id vcs_info_id user_id run_ord
       started finished result passed failed meta status has_coverage has_resources/
}
sub JSON_COLUMNS { qw/meta/ }

sub init {
    my $self = shift;
    $self->{+STATUS}        //= 'pending';
    $self->{+PASSED}        //= 0;
    $self->{+FAILED}        //= 0;
    $self->{+HAS_COVERAGE}  //= 0;
    $self->{+HAS_RESOURCES} //= 0;
    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::DB::Run - Row object for the C<runs> table.

=head1 DESCRIPTION

One row per run. C<meta> is JSON. C<result> is a tri-state boolean
(null = in flight, true = all jobs passed, false = at least one
failed). C<status> is the lifecycle string
(C<pending>/C<running>/C<complete>/C<broken>/C<canceled>); setting
status to C<canceled> asks the scheduler to terminate in-flight
jobs and stop dispatching. C<has_coverage> / C<has_resources>
flag whether this run produced coverage rows or resource samples.
C<vcs_info_id> is the optional VCS-context link parallel to
C<version_id>.

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
