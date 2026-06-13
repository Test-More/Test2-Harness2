package App::Yath2::Command::fake;
use v5.38;

use parent 'App::Yath2::Command';

use Getopt::Yath;

option_group {group => 'fake'}, sub {
    option($_, type => 'Bool', short => $_) for qw/x y z/;

    option_post_process 0 => sub ($options, $state) { print "\n\nAAAA\n\n"; $main::POST_HOOK++ };
};

1;
