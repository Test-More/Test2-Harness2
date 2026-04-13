use strict;
use warnings;
use Test2::V0;

ok(1, "stream2 event");

# This prints TAP directly to stdout (bypassing formatter)
print STDOUT "# a direct diagnostic\n";

ok(1, "another stream2 event");

done_testing;
