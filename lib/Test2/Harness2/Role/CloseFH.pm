package Test2::Harness2::Role::CloseFH;
use v5.38;

our $VERSION = '2.000000';

use Role::Tiny;

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Role::CloseFH - Idempotent close of a socket-backed endpoint.

=head1 DESCRIPTION

A one-method mixin for the framed endpoints that own a single socket filehandle
plus a C<closed> flag: L<Test2::Harness2::Role::Service::Connection> (the framed
transport) and L<Test2::Harness2::Util::FdPass::Control> (the C<yath spawn>
control channel). It closes the underlying filehandle at most once and records
the closed state, so a double C<close> (an EOF drop plus an explicit teardown,
say) is a harmless no-op.

The consumer stores its socket under the C<fh> slot and its closed flag under
the C<closed> slot -- both are HashBase C<< <fh >> / C<< +closed >> attributes on
the two consumers.

=head1 METHODS

=over 4

=item $endpoint->close

Close the underlying filehandle and mark the endpoint closed. Idempotent: a
second call returns immediately. The C<CORE::close> is eval-wrapped so an
already-invalid descriptor cannot throw.

=back

=cut

sub close ($self) {
    return if $self->{closed};
    $self->{closed} = 1;
    eval { CORE::close($self->{fh}); 1 };
    return;
}

1;

__END__

=pod

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness2/>.

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

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
