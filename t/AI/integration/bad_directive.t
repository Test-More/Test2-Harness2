use Test2::V0;

use Test2::Util qw/CAN_REALLY_FORK/;
use App::Yath2::Tester qw/yath/;

skip_all "This test requires forking" unless CAN_REALLY_FORK;

# TODO-118 (ticket Step 4): a single file with an unknown category
# (# HARNESS-CATEGORY-NETWORK) is a value-domain directive error, not a grammar
# error. It must fail ONLY that job -- as a synthetic E1 FAILURE that names the
# bad token -- and let the rest of the run complete. Pre-TODO-118 the runner's
# task_fields die aborted the ENTIRE run mid-submit (and reaped sibling runs on a
# persistent daemon). This is the end-to-end guard that one bad directive can no
# longer abort discovery or the run.

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-A'],
    test    => sub {
        my $out = shift;

        ok($out->{exit}, "run exits nonzero because one job failed");

        like($out->{output}, qr{Invalid harness directive}, "the bad-category file fails as a synthetic E1 failure");
        like($out->{output}, qr{not a valid category}i,     "the diagnostic explains the value-domain error");

        like($out->{output}, qr{PASSED.*good1\.tx}, "sibling good1 still scheduled, ran, and passed");
        like($out->{output}, qr{PASSED.*good2\.tx}, "sibling good2 still scheduled, ran, and passed");
    },
);

done_testing;
