package TestRootPreload;
use strict;
use warnings;

# A minimal staged preload library for the chunk 19.1 handshake test. Defines two
# stages so the reported stage map has something to assert: Alpha (the default)
# and Beta.
use Test2::Harness2::Runner::Preload;

stage Alpha => sub {
    default();
};

stage Beta => sub {
};

1;
