package CrashOncePreload;
use strict;
use warnings;

# A preload that makes the preload-root crash exactly once, to exercise §6.10
# preload-root crash resilience deterministically (no fragile external kill).
#
# On first load (marker absent) it creates the marker and POSIX::_exit()s the
# preload-root process abruptly during the handshake's _load_preloads pass --
# BEFORE the stage host comes up and WITHOUT a clean stage_host_exited. That is
# exactly the "crash" the runner must distinguish from a broken preload: it
# respawns a fresh preload-root, which loads this module again (marker now
# present) and proceeds normally, so the run recovers and the test runs.
BEGIN {
    my $marker = $ENV{T2H_CRASH_ONCE_MARKER};
    if ($marker && !-e $marker) {
        open(my $fh, '>', $marker) or die "Could not create crash marker '$marker': $!";
        print $fh "crashed\n";
        close($fh);

        require POSIX;
        POSIX::_exit(137);
    }
}

use Test2::Harness2::Runner::Preload;

stage CRASH => sub {
    preload 'List::Util';
};

1;
