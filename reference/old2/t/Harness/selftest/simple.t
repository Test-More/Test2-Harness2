#!/usr/bin/perl -w
# HARNESS-DURATION-SHORT

BEGIN { print "1..0 # SKIP only runs under yath (TEST2_HARNESS_ACTIVE)\n" and exit 0 unless $ENV{TEST2_HARNESS_ACTIVE}; }
use Test2::V0;
ok(1, "pass");
done_testing;
