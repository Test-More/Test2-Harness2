package App::Yath2::Client;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Spec;

# XXX TODO: App::Yath2::IPC, Test2::Harness2::IPC::Protocol, and
# Test2::Harness2::Client have been removed (see PR #390). This entire
# module needs to be reimplemented against the new IPC architecture.

use Object::HashBase qw{
    <settings
    <ipc <connect
    <yath_ipc
    <ipc_type
    <types
};

sub init {
    # XXX TODO: reimplment against new IPC architecture; App::Yath2::IPC and
    # Test2::Harness2::Client are gone (PR #390).
    die "App::Yath2::Client is not yet implemented\n";
}

sub ipc_text {
    # XXX TODO: needs reimplementing once App::Yath2::Client is restored
    die "App::Yath2::Client is not yet implemented\n";
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Client - FIXME

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 EXPORTS

=over 4

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


=pod

=cut POD NEEDS AUDIT

