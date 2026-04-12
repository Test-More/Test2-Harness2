# HARNESS-NO-STREAM
BEGIN { print "1..0 # SKIP only runs under yath (TEST2_HARNESS_ACTIVE)\n" and exit 0 unless $ENV{TEST2_HARNESS_ACTIVE}; }
use strict;
use warnings;
use Test2::Tools::Tiny;
use Test2::Tools::Subtest qw/subtest_streamed/;
# HARNESS-DURATION-SHORT

subtest_streamed foo => sub {
    subtest_streamed bar => sub {
        ok(1, 'baz');
    };
};

done_testing;
