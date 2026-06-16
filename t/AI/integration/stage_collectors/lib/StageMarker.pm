package StageMarker;
use strict;
use warnings;

use Test2::Harness2::Runner::Preload;

# A preload that defines a single default stage which prints a unique marker to
# both STDOUT and STDERR while it preloads. With chunk 4b the stage runs under
# its own non-test collector, so these markers land in the stage's events file
# and must still reach the rendered output (the gatherer reads the per-stage
# events files just like the runner stream).
stage MARK => sub {
    default;

    preload sub {
        print "STAGE-MARKER-STDOUT-VISIBLE\n";
        print STDERR "STAGE-MARKER-STDERR-VISIBLE\n";
    };
};

1;
