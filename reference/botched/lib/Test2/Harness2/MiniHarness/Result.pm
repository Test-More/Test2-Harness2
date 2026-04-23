package Test2::Harness2::MiniHarness::Result;
use strict;
use warnings;

our $VERSION = '2.000012';

use Test2::Harness2::Util::HashBase qw{
    <passed
    <exit_code
    <uuid
    <log_file
};

sub init {
    my $self = shift;

    $self->{+PASSED}    //= 0;
    $self->{+EXIT_CODE} //= -1;
    $self->{+UUID}      //= '';
    $self->{+LOG_FILE}  //= '';
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::MiniHarness::Result - Result object from a MiniHarness test execution

=head1 DESCRIPTION

Simple result object returned by L<Test2::Harness2::MiniHarness/run>.

=head2 ATTRIBUTES

=over 4

=item $bool = $result->passed

True if the test passed.

=item $int = $result->exit_code

Raw wait status of the child process.

=item $str = $result->uuid

The UUID for this test execution.

=item $path = $result->log_file

Path to the JSONL event log.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
