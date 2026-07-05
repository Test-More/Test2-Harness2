package App::Yath2::Options::Persist;
use v5.38;

our $VERSION = '2.000000';

use Getopt::Yath;

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Options::Persist - Persistent Runner options for Yath.

=head1 DESCRIPTION

This is where the command line options for the persistent runner are defined.

=head1 PROVIDED OPTIONS

=head3 Runner Options

=over 4

=item --daemon

=item --no-daemon

Start the runner as a daemon (Default: True)


=back


=cut

option_group {group => 'runner', category => "Runner Options"} => sub {
    option daemon => (
        type        => 'Bool',
        description => 'Start the runner as a daemon (Default: True)',
        default     => 1,
    );
};

1;

__END__

=pod

=encoding UTF-8

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness2/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
