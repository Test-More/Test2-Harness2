BEGIN { print "1..0 # SKIP only runs under yath (TEST2_HARNESS_ACTIVE)\n" and exit 0 unless $ENV{TEST2_HARNESS_ACTIVE}; }
use strict;
use warnings;
use Test2::Tools::Tiny;
use File::Spec;
# HARNESS-DURATION-SHORT

my $file = __FILE__;
$file =~ s/\.t$/.pm/;
$file = File::Spec->rel2abs($file);

require $file;

ok(file_loaded(), "file loaded, proper namespace, etc");

done_testing;
