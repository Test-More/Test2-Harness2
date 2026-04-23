BEGIN { print "1..0 # SKIP only runs under yath (TEST2_HARNESS_ACTIVE)\n" and exit 0 unless $ENV{TEST2_HARNESS_ACTIVE}; }
use Test2::V0;
# HARNESS-DURATION-SHORT
skip_all "Test breaks Devel::Cover db" if $ENV{T2_DEVEL_COVER};

$\ = '|';
$, = '|';

is($\, '|', 'set $\\');
is($,, '|', 'set $,');

done_testing
