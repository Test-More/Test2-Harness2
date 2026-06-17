package App::Yath2::Plugin::DaemonPlug;
use strict;
use warnings;

use Time::HiRes ();

use parent 'App::Yath2::Plugin';

our $VERSION = '2.000000';

# Chunk 17 fixture: a plugin whose setup() starts a long-lived background process
# via run_collected (the non-blocking, daemon-style collector form). The process
# records its pid and prints periodically forever -- the runner must capture that
# output as (DAEMON) events, must NOT hang on it at run/shutdown, and must kill it
# when the runner stops (it is a runner child, tracked in AUX_PIDS + watching the
# runner pid).
sub setup {
    my $this = shift;
    my ($settings) = @_;

    my $pidfile = $ENV{DAEMON_PIDFILE} or return;

    $this->run_collected($settings, 'daemon', sub {
        open(my $fh, '>', $pidfile) or die "Could not write daemon pidfile: $!";
        print $fh "$$\n";
        close($fh);

        $| = 1;
        my $i = 0;
        while (1) {
            $i++;
            print "DAEMON TICK $i\n";
            Time::HiRes::sleep(0.2);
        }
    });

    return;
}

1;
