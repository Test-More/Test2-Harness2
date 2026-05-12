package Test2::Harness2::Role::Resource::OptionParser;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;

use Role::Tiny;

# Default: no extra recognised prefixes. Consumers with their own
# inline `key=` forms override this to return an arrayref of bare key
# tokens (without the trailing `=`). The role-provided default keeps
# the role usable by consumers whose only inline kv form is `name=`.
sub _inline_key_prefixes { [] }

# Predicate consumed by parse_options: "is this $arg the first half of
# an unknown k=>v pair that should be silently dropped?" Returns true
# only when $arg is a plain key-shaped token (not numeric, not @file,
# not name=, not one of the consumer's declared inline key= prefixes)
# AND there is a following value to pair it with.
#
# Resources whose grammars do not fit this shape (Disk's /path:THR
# entries, Throttle's bare-numeric rule shorthand) implement their own
# _is_unknown_kv_arg locally and skip this role.
sub _is_unknown_kv_arg {
    my ($class, $arg, $has_next) = @_;

    return 0 unless $has_next;
    return 0 unless defined $arg;
    return 0 if ref $arg;
    return 0 if $arg =~ m{^[0-9]};
    return 0 if $arg =~ m{^@};
    return 0 if $arg =~ m{^name=};

    my $prefixes = $class->_inline_key_prefixes;
    croak ref($class) || $class, ": _inline_key_prefixes must return an ARRAY ref"
        unless ref($prefixes) eq 'ARRAY';

    for my $p (@$prefixes) {
        return 0 if $arg =~ m{^\Q$p\E=};
    }

    return 1;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Role::Resource::OptionParser - Shared parse_options predicate for resources with key=value inline grammars.

=head1 DESCRIPTION

Consumed by L<Test2::Harness2::Resource::CPU>,
L<Test2::Harness2::Resource::Memory>,
L<Test2::Harness2::Resource::UnixLimits>, and
L<Test2::Harness2::Resource::PipeLimits>, each of which has a
C<parse_options> implementation that needs to "drop unknown k=>v
pairs" coming through the resource-group settings hash. The predicate
is structurally identical across all four; only the list of
recognised inline C<key=> prefixes differs.

=head1 METHODS

=over 4

=item \@prefixes = $class->_inline_key_prefixes

Arrayref of bare key tokens (without the trailing C<=>) that the
consumer's C<parse_options> recognises as inline key/value entries.
Defaults to C<[]>. Consumers with extra inline forms override -- for
example, L<Test2::Harness2::Resource::CPU> returns C<['utilize']>.

=item $bool = $class->_is_unknown_kv_arg($arg, $has_next)

True when C<$arg> looks like the first half of an unknown C<key=>value>
pair from the resource-group settings: it has a following value, is
defined, is not a ref, does not begin with a digit, is not an C<@file>
entry, is not C<name=>, and does not start with any prefix in
C<_inline_key_prefixes>. C<parse_options> uses the result to consume
both args and continue past the unknown pair.

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
