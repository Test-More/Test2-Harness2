use Test2::V0;

use Test2::Util qw/CAN_REALLY_FORK/;

use App::Yath2::Tester qw/yath/;

skip_all "Cannot fork, skipping preload resource test" unless CAN_REALLY_FORK;
skip_all "This test requires forking" if $ENV{T2_NO_FORK};

# §4.7a: the preload Resource gates preload-directed tests on stage availability.
#  * require_missing.tx REQUIREs a stage absent from the map => resource returns -1
#    => the test is SKIPPED before its body runs.
#  * advisory_missing.tx names a missing stage advisorily => falls to default, runs.
#  * runs_in_alpha.tx asks for a present stage (ALPHA) => runs there.
my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-A', '-PReqPreload'],
    exit    => 0,
    test    => sub {
        my $out = shift;

        like($out->{output}, qr{(SKIPPED|# SKIP).*require_missing\.tx}i,
            'require_missing.tx was resource-skipped (its required stage is absent)');

        unlike($out->{output}, qr{this body must NOT run},
            'the skipped test body never executed');

        like($out->{output}, qr{PASSED.*advisory_missing\.tx},
            'advisory_missing.tx fell to the default stage and passed');

        like($out->{output}, qr{PASSED.*runs_in_alpha\.tx},
            'runs_in_alpha.tx ran in its present required stage');
    },
);

done_testing;
