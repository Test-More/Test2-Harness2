package App::Yath2::DB::DBIC::Schema;
use strict;
use warnings;

our $VERSION = '2.000012';

use parent 'DBIx::Class::Schema';

# Auto-load every Result class under App::Yath2::DB::DBIC::Result::*.
# The '+' prefix makes the namespace absolute (otherwise DBIC would
# look for App::Yath2::DB::DBIC::Schema::Result::*, one level too deep).
__PACKAGE__->load_namespaces(
    result_namespace        => '+App::Yath2::DB::DBIC::Result',
    resultset_namespace     => '+App::Yath2::DB::DBIC::ResultSet',
    default_resultset_class => '+DBIx::Class::ResultSet',
);

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::DB::DBIC::Schema - DBIx::Class schema for yath log archives.

=head1 DESCRIPTION

Loaded by L<App::Yath2::DB::DBIC>. Result classes live under
C<App::Yath2::DB::DBIC::Result::*>. The schema is bootstrapped via
F<share/schema/$flavor.sql> by L<App::Yath2::Role::DB::Backend>; this
class never calls C<deploy()>.

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

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
