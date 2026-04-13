package App::Yath2::Plugin::Options;
use strict;
use warnings;

use App::Yath2::Options;

option foobar => (
    prefix => 'testplugin',
    type => 'b',
);

1;
