#!/usr/bin/perl
BEGIN { print "1..0 # SKIP only runs under yath (TEST2_HARNESS_ACTIVE)\n" and exit 0 unless $ENV{TEST2_HARNESS_ACTIVE}; }
use strict;
use warnings;
# HARNESS-DURATION-SHORT

print "1..2\nok - A\nok - B";
