BEGIN { print "1..0 # SKIP only runs under yath (TEST2_HARNESS_ACTIVE)\n" and exit 0 unless $ENV{TEST2_HARNESS_ACTIVE}; }
use Test2::V0;
# HARNESS-DURATION-SHORT

my $file = __FILE__;
my $line = __LINE__ + 1;
sub throw { die("xxx") };

is(
    dies { throw() },
    "xxx at $file line $line.\n",
    "Got exception as expected"
);

done_testing;
