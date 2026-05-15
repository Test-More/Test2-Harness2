# HARNESS-CONFLICTS YATH
use Test2::V0;
use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep/;
use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath/;

my $dir = tempdir(CLEANUP => 1);
my $script = "$dir/x.pl";
open my $sfh, '>', $script; print $sfh "1;\n"; close $sfh;

my $lib = "$dir/lib";
mkdir $lib; mkdir "$lib/Test2"; mkdir "$lib/Test2/Harness2"; mkdir "$lib/Test2/Harness2/Resource";
open my $pfh, '>', "$lib/Test2/Harness2/Resource/StagePreloader.pm" or die $!;
print $pfh <<'EOF';
package Test2::Harness2::Resource::StagePreloader;
use Test2::Harness2::Resource::Preload;
use parent -norequire, 'Test2::Harness2::Resource::Preload';
sub init { my $s=shift; $s->{name}//='BASE'; $s->{modules}//=[]; $s->SUPER::init() }
1;
EOF
close $pfh;

yath(command => 'start', args => ["--workdir=$dir", '-R', 'Test2::Harness2::Resource::StagePreloader', "--dev-lib=$lib"], exit => 0);
sleep 1;

yath(
    command => 'spawn',
    args    => ["--workdir=$dir", '-s', 'NONEXISTENT', '--', $script],
    exit    => sub { $_[0] != 0 },
    test    => sub {
        like($_[0]->{output}, qr/NONEXISTENT/, 'error mentions stage');
    },
);

yath(command => 'stop', args => ["--workdir=$dir"], exit => 0);
done_testing;
