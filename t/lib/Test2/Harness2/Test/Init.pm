package Test2::Harness2::Test::Init;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Spec();

use Test2::Harness2::Util qw/clean_path/;
use App::Yath2();

# Run the pin check at use/require time. Importing this module is the
# initialization step -- callers do not need to invoke anything.
__PACKAGE__->pin_local_v2;

sub pin_local_v2 {
    my $class = shift;

    require App::Yath::Script::V2;
    my $loaded = $INC{'App/Yath/Script/V2.pm'} or return;

    my $apppath = App::Yath2->app_path;
    my $want = File::Spec->catfile($apppath, 'App', 'Yath', 'Script', 'V2.pm');

    $loaded = clean_path($loaded);
    $want   = clean_path($want);

    return if $loaded eq $want;

    croak "App::Yath::Script::V2 resolved to '$loaded', expected '$want'.\n"
        . "An installed copy is shadowing the in-tree V2; check \@INC ordering "
        . "or remove the stale install.";
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Test::Init - Test-time enforcement hook for the in-tree
harness rewrite.

=head1 DESCRIPTION

Loaded by integration-test scaffolding to assert invariants that only
matter when the test suite is run from a checkout. Currently:

=over 4

=item *

Pins L<App::Yath::Script::V2> to the copy under the checkout's C<lib/>,
so a stale CPAN install at the same version cannot silently shadow the
in-tree rewrite.

=back

The check fires once at C<use>/C<require> time. Failures are loud
C<croak>s -- there is no way to ignore them, by design.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=cut
