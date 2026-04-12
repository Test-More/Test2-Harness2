BEGIN { print "1..0 # SKIP only runs under yath (TEST2_HARNESS_ACTIVE)\n" and exit 0 unless $ENV{TEST2_HARNESS_ACTIVE}; }
use Test2::V0;
use File::Spec;
# HARNESS-NO-FORK
# HARNESS-DURATION-SHORT

my $path = File::Spec->canonpath('t/Harness/selftest/relative_paths_no_fork.t');

skip_all "This test must be run from the project root."
    unless -f $path;

is(__FILE__, $path, "__FILE__ is relative");
is(__FILE__, $0, "\$0 is relative");

sub {
    my ($pkg, $file) = caller(0);
    is($file, $path, "file in caller is relative");
}->();

done_testing;
