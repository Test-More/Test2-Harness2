# HARNESS-CONFLICTS YATH
use Test2::V0;
use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep/;
use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath/;

my $dir = tempdir(CLEANUP => 1);
my $lib = "$dir/lib";
mkdir $lib;
mkdir "$lib/Yathspawn"; mkdir "$lib/Test2"; mkdir "$lib/Test2/Harness2"; mkdir "$lib/Test2/Harness2/Resource";

open my $mfh, '>', "$lib/Yathspawn/Marker.pm" or die $!;
print $mfh "package Yathspawn::Marker;\nour \$LOADED = 'yes';\n1;\n";
close $mfh;

open my $pfh, '>', "$lib/Test2/Harness2/Resource/StagePreloader.pm" or die $!;
print $pfh <<'EOF';
package Test2::Harness2::Resource::StagePreloader;
use Test2::Harness2::Resource::Preload;
use parent -norequire, 'Test2::Harness2::Resource::Preload';
sub init {
    my $s = shift;
    $s->{name}    //= 'BASE';
    $s->{modules} //= ['Yathspawn::Marker'];
    $s->SUPER::init();
}
1;
EOF
close $pfh;

my $script = "$dir/check_marker.pl";
open my $sfh, '>', $script or die $!;
print $sfh <<'EOF';
my $loaded_path = $INC{'Yathspawn/Marker.pm'} // 'MISSING';
my $marker = $Yathspawn::Marker::LOADED // 'unset';
print "loaded_path=$loaded_path\n";
print "marker=$marker\n";
exit 0;
EOF
close $sfh;

yath(command => 'start', args => ["--workdir=$dir", '-R', 'Test2::Harness2::Resource::StagePreloader', "--dev-lib=$lib"], exit => 0);
sleep 1;

yath(
    command => 'spawn',
    args    => ["--workdir=$dir", '-s', 'BASE', '--', $script],
    exit    => 0,
    test    => sub {
        like($_[0]->{output}, qr{loaded_path=.+/Yathspawn/Marker\.pm}, 'marker in %INC');
        like($_[0]->{output}, qr{marker=yes}, 'marker global visible');
    },
);

yath(command => 'stop', args => ["--workdir=$dir"], exit => 0);
done_testing;
