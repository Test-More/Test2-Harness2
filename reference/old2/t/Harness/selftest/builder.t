BEGIN { print "1..0 # SKIP only runs under yath (TEST2_HARNESS_ACTIVE)\n" and exit 0 unless $ENV{TEST2_HARNESS_ACTIVE}; }
use Test::More;
use strict;
use warnings;
# HARNESS-DURATION-SHORT

ok(1, "pass");

done_testing;
