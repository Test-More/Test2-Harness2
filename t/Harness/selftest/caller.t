package FooBarBaz;
BEGIN { print "1..0 # SKIP only runs under yath (TEST2_HARNESS_ACTIVE)\n" and exit 0 unless $ENV{TEST2_HARNESS_ACTIVE}; }
use strict;
use warnings;
# HARNESS-DURATION-SHORT

use Test2::V0;

is([caller(0)], [], "No caller at the flat test level");
is(__PACKAGE__, 'FooBarBaz', "inside main package");
like(__FILE__, qr/caller\.t$/, "__FILE__ is correct");
is(__LINE__, 12, "Got the correct line number");
is($@, '', '$@ set to empty string');

done_testing;