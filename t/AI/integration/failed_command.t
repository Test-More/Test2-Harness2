# HARNESS2: conflicts yath
use Test2::V0;

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;

use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath/;

my $tmp = tempdir(CLEANUP => 1);
my $td  = "$tmp/tests";
make_path($td);

open(my $pf, '>', "$td/pass.tx") or die $!;
print $pf "use Test2::V0;\nok(1, 'p');\ndone_testing;\n";
close $pf;

open(my $ff, '>', "$td/fail.tx") or die $!;
print $ff "use Test2::V0;\nok(0, 'f');\ndone_testing;\n";
close $ff;

my $archive = "$tmp/run.yath";

yath(
    command => 'test',
    args    => [$td, '--ext=tx', "--log-file=$archive"],
    exit    => T(),
);

ok(-f $archive, 'archive written');

yath(
    command => 'failed',
    args    => [$archive],
    env     => {TABLE_TERM_SIZE => 1000, TS_TERM_SIZE => 1000},
    exit    => 0,
    test    => sub {
        my $out = shift;
        like($out->{output},   qr/fail\.tx/, 'failed lists fail.tx');
        unlike($out->{output}, qr/pass\.tx/, 'failed does not list pass.tx');
    },
);

yath(
    command => 'failed',
    args    => ['--brief', $archive],
    exit    => 0,
    test    => sub {
        my $out = shift;
        like($out->{output},   qr/fail\.tx/, 'failed --brief lists fail.tx');
        unlike($out->{output}, qr/pass\.tx/, 'failed --brief does not list pass.tx');
        unlike($out->{output}, qr/Test File/, 'failed --brief omits header');
    },
);

done_testing;
