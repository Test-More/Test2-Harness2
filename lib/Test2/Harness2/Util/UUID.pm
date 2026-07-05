package Test2::Harness2::Util::UUID;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Test2::Util::UUID();

use Importer 'Importer' => 'import';

our @EXPORT    = qw/gen_uuid/;
our @EXPORT_OK = qw/gen_uuid/;

# Test2::Util::UUID builds gen_uuid() dynamically (no callable
# Test2::Util::UUID::gen_uuid symbol exists), so fetch the coderef once and wrap
# it. This is the backend mint point: it produces v7 UUIDs normalized to UPPER
# case. R9 boundary normalization: the DB layer's canonical form is lowercase,
# but that lowercasing lives solely in App::Yath2::Util::UUID, NOT here -- the 11
# backend importers rely on the historically UPPERCASE output.
my $T2_GEN_UUID = Test2::Util::UUID->get_gen_uuid->{gen_uuid}
    or croak "Test2::Util::UUID did not provide a gen_uuid backend";

sub gen_uuid { return uc($T2_GEN_UUID->()) }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::UUID - Utils for generating UUIDs.

=head1 DESCRIPTION

This module provides a consistent UUID source for all of Test2::Harness2. It
generates B<v7> UUIDs via L<Test2::Util::UUID>, normalized to B<upper> case
(R9: the App::Yath2 DB boundary owns lowercasing, not this module).

=head1 SYNOPSIS

    use Test2::Harness2::Util::UUID qw/gen_uuid/;

    my $uuid = gen_uuid;

=head1 EXPORTS

=over 4

=item $uuid = gen_uuid()

Generate a v7 UUID (via L<Test2::Util::UUID>), returned in B<upper> case.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness2/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
