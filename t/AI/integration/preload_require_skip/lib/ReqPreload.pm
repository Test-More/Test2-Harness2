package ReqPreload;
use strict;
use warnings;

# A staged preload with a real stage (ALPHA) and a default. Used to exercise the
# §4.7a preload Resource: a test that REQUIREs a stage which does not exist in this
# map is permanently unavailable and must be skipped (or failed under
# --fail-on-resource-skip), while an advisory test that names a missing stage falls
# to the default stage and runs.
use Test2::Harness2::Runner::Preload;

stage DEFAULT => sub {
    default();
};

stage ALPHA => sub {
};

1;
