package CrashMidRunPreload;
use strict;
use warnings;

# Mid-run resilience for the scheduler-only runner's synchronous file_stage
# resolution. file_stage is answered IN A FORKED STAGE (the runner asks any live
# `preload-<name>` peer over resolve_file_stages mid-run -- not the preload-root,
# and an empty stage map skips the resolver entirely, so file_stage always runs in
# a stage). This fixture has TWO stages so that when the stage answering a resolve
# dies mid-request, the runner must fail over to the other live stage and finish
# the resolution rather than hang for 30s.
#
# The file_stage callback (inherited by every stage) POSIX::_exit(137)s exactly
# once, keyed off a per-run marker: the first stage to answer a resolve crashes;
# the runner must notice that resolver's channel drop, retry against the surviving
# stage (marker now present -> it returns the stage normally), and complete the run.

use Test2::Harness2::Runner::Preload;

stage A => sub {
    preload 'List::Util';
};

stage B => sub {
    preload 'Scalar::Util';
};

file_stage sub {
    my ($file) = @_;

    my $marker = $ENV{T2H_MIDRUN_CRASH_MARKER};
    if ($marker && !-e $marker) {
        open(my $fh, '>', $marker) or die "Could not create midrun crash marker '$marker': $!";
        print $fh "crashed\n";
        close($fh);

        require POSIX;
        POSIX::_exit(137);
    }

    # Route the test to the stage that survives the crash. _resolver_identity asks
    # peers in sorted order, so 'A' answers (and crashes) first; 'B' is the survivor.
    return 'B';
};

1;
