package StageDispatch;
use strict;
use warnings;

use Test2::Harness2::Runner::Preload;

# Chunk 5d: a preload defining two named, non-default stages. The runner dispatches
# each test to its assigned stage over that stage's preload-<stage>.socket (no more
# dispatch.jsonl polling). file_stage routes alpha.tx -> ALPHA and beta.tx -> BETA;
# each stage preloads a stage-specific package, and each test asserts that ONLY its
# own stage's package is loaded -- proving the job ran in the right stage's
# preloaded interpreter, i.e. that the runner connected out to the correct socket.

file_stage sub {
    my ($file) = @_;
    return 'ALPHA' if $file =~ m/alpha\.tx$/;
    return 'BETA'  if $file =~ m/beta\.tx$/;
    return;
};

stage ALPHA => sub {
    preload sub { $StageDispatch::ALPHA_LOADED = 1 };
};

stage BETA => sub {
    preload sub { $StageDispatch::BETA_LOADED = 1 };
};

1;
