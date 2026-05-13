# HARNESS-CONFLICTS YATH
use Test2::V0;
use File::Temp qw/tempdir/;
use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath/;

my $dir = tempdir(CLEANUP => 1);

# 'start' does not auto-inject JobCount on Linux unless -j is given,
# so pass -j here to verify the resources command can surface JobCount.
yath(command => 'start', args => ["--workdir=$dir", '-j', '2'], exit => 0);

# One-shot reports the JobCount resource we asked for.
yath(
    command => 'resources',
    args    => ["--workdir=$dir"],
    exit    => 0,
    test    => sub {
        my $o = shift;
        like($o->{output}, qr/JobCount/i, 'JobCount resource listed');
    },
);

yath(command => 'stop', args => ["--workdir=$dir", '--timeout=10'], exit => 0);

done_testing;
