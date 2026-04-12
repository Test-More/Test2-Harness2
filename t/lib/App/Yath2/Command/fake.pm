package App::Yath2::Command::fake;
use strict;
use warnings;

use parent 'App::Yath2::Command';

use App::Yath2::Options;

option_group {prefix => 'fake'}, sub {
    option($_, short => $_) for qw/x y z/;

    post sub { print "\n\nAAAA\n\n";  $main::POST_HOOK++ };
};

1;
