package App::Yath2UI;
use strict;
use warnings;

our $VERSION = '2.000011';

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2UI - Database schema and web server for the Yath test harness.

=head1 DESCRIPTION

C<App::Yath2UI> is the UI layer of the Yath test harness distribution. It
ships the DBIC schema for persisting test runs and the Plack-based web
server for browsing results.

This module is an entry point for documentation and version tracking only;
it has no executable code. See L<App::Yath2UI::Schema> and
L<App::Yath2UI::Server> for the actual components.

See L<Test2::Harness2> for the runtime and L<App::Yath2> for the CLI.

=head1 SOURCE

The source code repository for Test2-Harness2 can be found at
L<https://github.com/Test-More/Test2-Harness/>.

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
