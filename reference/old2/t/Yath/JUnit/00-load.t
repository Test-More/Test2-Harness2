use 5.010000;
use strict;
use warnings;
use Test::More;

plan tests => 1;

BEGIN {
    use_ok('App::Yath2::Renderer::JUnit') || print "Bail out!\n";
}

diag("Testing App::Yath2::Renderer::JUnit $App::Yath2::Renderer::JUnit::VERSION, Perl $], $^X");
