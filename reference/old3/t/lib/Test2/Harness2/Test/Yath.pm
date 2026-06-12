package Test2::Harness2::Test::Yath;
use strict;
use warnings;

our $VERSION = '2.000011';

# Order matters:
#   1. Set YATH_TESTER_INIT BEFORE loading App::Yath2::Tester so its
#      load-time block sees it and pulls in the V2 pin (and any
#      future test-only invariants we add to
#      Test2::Harness2::Test::Init).
#   2. Load Tester. Its load-time hook will require
#      Test2::Harness2::Test::Init, which croaks loud if @INC
#      misroutes App::Yath::Script::V2.
#   3. Re-export Tester's public API so tests have one entry point.
BEGIN { $ENV{YATH_TESTER_INIT} = 1 unless defined $ENV{YATH_TESTER_INIT} }

use App::Yath2::Tester qw/yath make_example_dir tester_ipc_dir/;

use Importer Importer => 'import';
our @EXPORT_OK = qw/yath make_example_dir tester_ipc_dir/;

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Test::Yath - Canonical wrapper for in-tree Yath
integration tests.

=head1 SYNOPSIS

    use lib 't/lib';
    use Test2::Harness2::Test::Yath qw/yath make_example_dir/;

    yath(
        command => 'help',
        args    => [],
        exit    => 0,
        test    => sub { ... },
    );

=head1 DESCRIPTION

Single entry point for everything under C<t/Yath/integration/>. It

=over 4

=item *

sets C<$ENV{YATH_TESTER_INIT} = 1> in C<BEGIN> so
L<App::Yath2::Tester>'s load-time hook fires and pulls in
L<Test2::Harness2::Test::Init> (currently: the
L<App::Yath::Script::V2> pin assertion);

=item *

re-exports C<yath()> and C<make_example_dir()> from
L<App::Yath2::Tester>.

=back

Integration tests should always go through this module rather than
C<use App::Yath2::Tester> directly. Direct use of C<App::Yath2::Tester>
is reserved for downstream consumers that do not want the in-tree
test-side hooks.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=cut
