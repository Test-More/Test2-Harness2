package App::Yath2::Plugin::Options;
use strict;
use warnings;

use Getopt::Yath;

option_group {group => 'testplugin', prefix => 'testplugin'} => sub {
    option foobar => (
        type => 'Bool',
    );
};

1;
