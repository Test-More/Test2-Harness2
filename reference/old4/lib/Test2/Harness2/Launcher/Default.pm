package Test2::Harness2::Launcher::Default;
use strict;
use warnings;

our $VERSION = '2.000000';

sub new {
    my $class = shift;
    my $delegate = $class->delegate_class;
    (my $file = $delegate) =~ s{::}{/}g;
    require "$file.pm";
    return $delegate->new(@_);
}

sub delegate_class {
    return $^O eq 'MSWin32'
        ? 'Test2::Harness2::Launcher::Win32'
        : 'Test2::Harness2::Launcher::ForkExec';
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Launcher::Default - Pick the platform-appropriate
launcher at construction time and return it.

=head1 DESCRIPTION

Tiny factory. C<new(...)> picks
L<Test2::Harness2::Launcher::Win32> on MSWin32 and
L<Test2::Harness2::Launcher::ForkExec> everywhere else, and returns a
fresh instance of that class with the same arguments. The returned
object I<is> the delegate -- there is no
C<Test2::Harness2::Launcher::Default> instance and no second process.
The Default name exists so callers can write "give me the right
launcher" without branching on C<$^O> themselves.

=head1 SYNOPSIS

    use Test2::Harness2::Launcher::Default;

    my $l = Test2::Harness2::Launcher::Default->new(name => 'default');

    # $l isa Test2::Harness2::Launcher::ForkExec on POSIX
    # $l isa Test2::Harness2::Launcher::Win32    on MSWin32

    my %reply = $l->launch(\%spec);

=head1 CLASS METHODS

=over 4

=item $obj = $class->new(%args)

Pick the platform delegate, C<require> it, and construct it with the
given arguments.

=item $delegate_class = $class->delegate_class

Return the class name C<new> would dispatch to on the current
platform. Useful for diagnostics / tests.

=back

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
