package Test2::Harness2::Runner::Run::Resource;
use strict;
use warnings;

our $VERSION = '2.000000';

use Object::HashBase qw{
    @Test2::Harness2::Runner::Resource
};

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::Run::Resource - Row object for run-scoped
C<resources> rows.

=head1 DESCRIPTION

Subclass of L<Test2::Harness2::Runner::Resource> used when a
C<resources> row carries a non-null C<run_id>. Identical column set
and behavior; the only purpose of the subclass is to make
C<isa('Test2::Harness2::Runner::Run::Resource')> a one-line test for
"this resource is scoped to a specific run".

The runner-global / run-scoped split is decided in
L<Test2::Harness2::Runner::Resource/class_for_row>.

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
