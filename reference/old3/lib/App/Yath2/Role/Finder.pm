package App::Yath2::Role::Finder;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;

use Role::Tiny;

# Every finder must implement find_files. It receives an arrayref of
# plugin objects (may be empty) and returns an arrayref of objects that
# consume Test2::Harness2::Role::TestFile.
requires 'find_files';

# Canonical name for this finder implementation. Defaults to the last
# component of the class name, lowercased. Useful for diagnostics and
# for option-driven class selection.
sub finder_name {
    my $self  = shift;
    my $class = ref($self) || $self;
    (my $name = $class) =~ s/^.*:://;
    return lc($name);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Role::Finder - Role for test-file finders.

=head1 DESCRIPTION

A finder locates the set of test files that a run should execute.
Consumers implement L</find_files> and may optionally override
L</finder_name>.

This role exists so that alternative finder implementations
(git-change-aware, database-driven, multi-project, etc.) all present
a uniform interface to the harness command layer.

=head1 REQUIRED METHODS

=over 4

=item \@test_files = $finder->find_files(\@plugins)

Return an arrayref of objects that consume
L<Test2::Harness2::Role::TestFile>.  The C<@plugins> arrayref may be
empty.  The returned list is the complete set of tests the caller
should run; callers must not make assumptions about sort order beyond
what the finder documents.

=back

=head1 PROVIDED METHODS

=over 4

=item $name = $finder->finder_name

Short identifier for this finder implementation, derived from the
last component of the class name, lowercased.  Override for a more
descriptive label.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

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

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
