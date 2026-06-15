package App::Yath2::Options::Yath;
use strict;
use warnings;

our $VERSION = '2.000000';

use Getopt::Yath;

# NOTE: In the full pre_ai distribution App::Yath::Options::Yath was a large
# option group that overlapped heavily with what is now provided by
# App::Yath2::Options::PreCommand and App::Yath2::Options::Debug (version,
# help, show-opts, dev-libs, etc). Porting it wholesale would duplicate those
# options. The DB/server/client commands only consume the 'project' and 'user'
# values from the 'yath' group, so this shim provides exactly those two and
# nothing else.
option_group {group => 'yath', category => 'Yath Options'} => sub {
    option project => (
        type        => 'Scalar',
        alt         => ['project-name'],
        description => 'This lets you provide a label for your current project/codebase. This is best used in a .yath.rc file.',
    );

    option user => (
        type          => 'Scalar',
        description   => 'Username to associate with logs, database entries, and yath servers.',
        from_env_vars => [qw/YATH_USER USER/],
    );
};

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::Yath - Project/user options for Yath UI commands.

=head1 DESCRIPTION

=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED

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
