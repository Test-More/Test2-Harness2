package RootPidPreload;
use strict;
use warnings;

# Test preload for the preload-root PROCESS crash-mid-run path (§6.10). The runner
# spawns the preload-root, which loads this library during its handshake -- in the
# preload-root process itself, before any stage forks. So $$ here IS the preload-root
# pid: record it (env-gated) so the test can SIGKILL the live preload-root mid-run and
# assert the runner respawns it and the run recovers.
BEGIN {
    if (my $pidfile = $ENV{T2H_PRELOAD_ROOT_PIDFILE}) {
        if (open(my $fh, '>', $pidfile)) {
            print $fh "$$\n";
            close($fh);
        }
    }
}

use Test2::Harness2::Runner::Preload;

stage AAA => sub {
    preload 'List::Util';
};

1;
