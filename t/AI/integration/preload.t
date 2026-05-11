# HARNESS-CONFLICTS YATH
use Test2::V0;

use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath/;

use Test2::Util qw/CAN_REALLY_FORK/;

skip_all "Cannot fork, skipping preload test"
    unless CAN_REALLY_FORK;

skip_all "T2_NO_FORK is set" if $ENV{T2_NO_FORK};

# Port of reference/legacy/t/integration/preload.t, simplified for the
# non-staged preload subsystem. Original used file_stage routing and
# named stages (AAA/BBB/CCC/FAST/SLOW); those no longer exist. What
# survives is the user-visible contract:
#
#   * `-PMod` causes Mod to be loaded once in the preload service and
#     remain in %INC for tests routed through the default bucket.
#   * Multiple `-P` modules in one invocation all preload.
#   * `HARNESS-PRELOAD: <no>` opts a test out of the preload.
#   * A preload that dies at compile time fails `yath test` with a
#     non-zero exit and surfaces the error message in the output.
#   * A preload that references a missing module fails the same way
#     and surfaces the `Can't locate` error.

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

local $ENV{TABLE_TERM_SIZE} = 500;

yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-A', '-PAISimplePreload', '-PAIPreload'],
    exit    => 0,
    test    => sub {
        my $out = shift;

        my $filtered = join "\n" => grep { m/(PASSED|FAILED|RETRY).*\.tx/ } split /\n/, $out->{output};

        like($filtered, qr{PASSED.*no_preload\.tx},   'no_preload.tx ran (HARNESS-PRELOAD: <no> opt-out)');
        like($filtered, qr{PASSED.*preload_test\.tx}, 'preload_test.tx ran with AISimplePreload preloaded');
        like($filtered, qr{PASSED.*multi_test\.tx},   'multi_test.tx ran with both modules preloaded');
    },
);

yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-A', '-PAIBroken'],
    exit    => T(),
    test    => sub {
        my $out = shift;
        like($out->{output}, qr{This is broken}, "broken preload's die message surfaced to user");
    },
);

yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-A', '-PAIBadDep'],
    exit    => T(),
    test    => sub {
        my $out = shift;
        like(
            $out->{output},
            qr{Can't locate AIBadDep/Does/Not/Exist\.pm},
            "missing-dep preload error surfaced to user",
        );
    },
);

# Persistent mode: legacy convention -- skip under AUTOMATED_TESTING
# because real daemonization + yath stop is fragile under CI.
unless ($ENV{AUTOMATED_TESTING}) {
    # yath run does not carry the Finder option group, so --ext does
    # not exist there; enumerate the .tx files explicitly.
    my @tx_files = glob "$dir/*.tx";

    yath(
        command => 'start',
        args    => ['-PAISimplePreload', '-PAIPreload'],
        exit    => 0,
        test    => sub {
            yath(
                command => 'run',
                args    => [@tx_files],
                exit    => 0,
                test    => sub {
                    my $out = shift;
                    my $filtered = join "\n" => grep { m/(PASSED|FAILED|RETRY).*\.tx/ } split /\n/, $out->{output};

                    like($filtered, qr{PASSED.*no_preload\.tx},   'no_preload.tx ran under daemon');
                    like($filtered, qr{PASSED.*preload_test\.tx}, 'preload_test.tx ran under daemon');
                    like($filtered, qr{PASSED.*multi_test\.tx},   'multi_test.tx ran under daemon');
                },
            );

            yath(command => 'stop', exit => 0);
        },
    );
}

done_testing;
