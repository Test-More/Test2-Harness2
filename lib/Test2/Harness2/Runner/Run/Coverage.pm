package Test2::Harness2::Runner::Run::Coverage;
use strict;
use warnings;

our $VERSION = '2.000000';

use Object::HashBase qw{
    +_handle
    <coverage_id
    <run_id
    <project_id
    <source_file
    <stamp
    <payload
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Row';

sub TABLE        { 'coverage' }
sub PRIMARY_KEY  { 'coverage_id' }
sub COLUMNS      { qw/coverage_id run_id project_id source_file stamp payload/ }
sub JSON_COLUMNS { qw/payload/ }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Runner::Run::Coverage - Row object for the C<coverage> table.

=head1 DESCRIPTION

One row per (coverage-producing run, source_file). C<payload> is
JSON with the canonical shape

    {
      "subs":       { "Foo::bar" => [...tests...] },
      "file_level": [...tests...],
      "meta":       { "managers" => [...] }
    }

See C<ARCHITECTURE.md> for the full description and the canonical
"latest" / "merge several runs" queries.

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
