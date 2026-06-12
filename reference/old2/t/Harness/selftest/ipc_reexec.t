BEGIN { print "1..0 # SKIP only runs under yath (TEST2_HARNESS_ACTIVE)\n" and exit 0 unless $ENV{TEST2_HARNESS_ACTIVE}; }
use strict;
use warnings;
# HARNESS-NO-FORK
# HARNESS-DURATION-SHORT

BEGIN { $INC{'Test2/Formatter/Stream.pm'} && exec($^X, $0); };
# Force into stdout
BEGIN {
    delete $ENV{T2_STREAM_DIR};
    delete $ENV{T2_FORMATTER};
}

use Test::Builder;
use Test2::V0;

ok 1, "test runs correctly in IPC mode";
done_testing;
