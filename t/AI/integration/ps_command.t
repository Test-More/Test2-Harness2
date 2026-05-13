# HARNESS-CONFLICTS YATH
use Test2::V0;
use File::Temp qw/tempdir/;
use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath/;

my $dir = tempdir(CLEANUP => 1);

yath(command => 'start', args => ["--workdir=$dir"], exit => 0);

# No active runs -> ps shows the daemon but reports zero in-flight jobs.
yath(
    command => 'ps',
    args    => ["--workdir=$dir"],
    exit    => 0,
    test    => sub {
        my $o = shift;
        like($o->{output}, qr/Daemon|service|harness/i, 'mentions the daemon');
        like($o->{output}, qr/0 in[- ]?flight|no in[- ]?flight|empty/i, 'reports no in-flight jobs');
    },
);

yath(command => 'stop', args => ["--workdir=$dir", '--timeout=10'], exit => 0);

done_testing;
