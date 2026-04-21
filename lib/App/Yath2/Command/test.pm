package App::Yath2::Command::test;
use strict;
use warnings;

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Harness',
    'App::Yath2::Options::Yath',
);

sub new { shift }

sub name { 'test' }

sub run { print "Hello Test\n"; }

1;
