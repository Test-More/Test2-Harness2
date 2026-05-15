# HARNESS2: conflicts yath
use Test2::V0;
use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep/;
use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath/;

my $dir = tempdir(CLEANUP => 1);
my $script = "$dir/exit7.pl";
open my $sfh, '>', $script or die $!;
print $sfh "exit 7;\n";
close $sfh;

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
    args    => ["--workdir=$dir", '-s', 'BASE', '--', $script],
    exit    => 7,
);

yath(command => 'stop', args => ["--workdir=$dir"], exit => 0);
done_testing;
