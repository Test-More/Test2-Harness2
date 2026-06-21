package TestPreload;
use strict;
use warnings;
use Time::HiRes qw/time/;

use Test2::Harness2::Runner::Preload;

# Stage selection is client-side: tests carry a HARNESS-STAGE directive and the
# runner routes them against this stage map. aaa.tx / bbb.tx ask for AAA / BBB.
stage AAA => sub {
    preload 'AAA';

    stage BBB => sub {
        preload 'BBB';
    };
};

our %HOOKS;
stage CCC => sub {
    $HOOKS{INIT} = [time(), $$];
    pre_fork sub   { $HOOKS{PRE_FORK}   = [time(), $$] };
    post_fork sub  { $HOOKS{POST_FORK}  = [time(), $$] };
    pre_launch sub { $HOOKS{PRE_LAUNCH} = [time(), $$] };

    preload 'CCC';
};

stage FAST => sub {
    default;

    preload 'FAST';

    stage SLOW => sub {
        preload 'SLOW';
    };
};

1;
