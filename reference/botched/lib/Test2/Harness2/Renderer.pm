package Test2::Harness2::Renderer;
use strict;
use warnings;

our $VERSION = '2.000012';

use Test2::Harness2::Util::HashBase;

my %HAS_RENDER_EVENT_CACHE;

sub has_render_event {
    my ($class) = @_;

    return $HAS_RENDER_EVENT_CACHE{$class}
        if exists $HAS_RENDER_EVENT_CACHE{$class};

    my $sub = $class->can('render_event');

    # Must exist and must NOT be inherited from the base class (which doesn't define it)
    $HAS_RENDER_EVENT_CACHE{$class} = ($sub && $class ne __PACKAGE__) ? 1 : 0;

    return $HAS_RENDER_EVENT_CACHE{$class};
}

sub produces_terminal_output { 0 }

sub start  { }
sub finish { }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Renderer - Base class for Test2::Harness2 renderers.

=head1 DESCRIPTION

Simple base class for renderers used by L<Test2::Harness2>.

Subclasses may implement C<render_event($event)> to receive events one at a
time. Use C<has_render_event($class)> to check whether a class implements it.

=head1 METHODS

=over 4

=item $bool = $renderer->produces_terminal_output()

Returns false (0) by default. Override in subclasses that write to a terminal.

=item has_render_event($class)

Returns true if C<$class> defines C<render_event>. Results are cached per class.

=item $renderer->start(%args)

Hook called before rendering begins. When used per-test in MiniHarness, receives
C<< log_file => $path, per_test => 1 >>. No-op in the base class.

=item $renderer->finish(%args)

Hook called after rendering is complete. When used per-test in MiniHarness,
receives C<< log_file => $path, per_test => 1 >>. No-op in the base class.

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
