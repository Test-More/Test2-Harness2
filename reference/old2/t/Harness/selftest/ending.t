# HARNESS-DURATION-SHORT
package FooBarBaz;
BEGIN { print "1..0 # SKIP only runs under yath (TEST2_HARNESS_ACTIVE)\n" and exit 0 unless $ENV{TEST2_HARNESS_ACTIVE}; }
use strict;
use warnings;

use Test2::V0;

open(my $fh, '<', __FILE__) or die "Could not open this file!: $!";
my @end = <$fh>;
close($fh);

is($end[-1], 'done_testing', "no semicolon or newline is present at the end of this file");

done_testing