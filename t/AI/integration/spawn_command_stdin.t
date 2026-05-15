# HARNESS2: conflicts yath
use Test2::V0;
use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep/;
use IPC::Open3 qw/open3/;
use Symbol qw/gensym/;
use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath tester_ipc_dir/;
use App::Yath2::Util qw/find_yath/;
use App::Yath2;

my $dir = tempdir(CLEANUP => 1);
my $script = "$dir/cat.pl";
open my $sfh, '>', $script or die $!;
print $sfh 'while (<STDIN>) { print "GOT: $_" } exit 0;', "\n";
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

# Drive stdin ourselves via open3 — the yath() helper inherits parent stdin
# and offers no way to write to the child's stdin.  We replicate the command
# the helper would build: $^X + lib flags + yath binary + -D flag + subcommand.
my $yath    = find_yath();
my $apppath = App::Yath2->app_path;

my @lib_flags = map { "-I$_" } grep { $_ ne '.' } @INC;

my @cmd = (
    $^X,
    @lib_flags,
    $yath,
    "-D$apppath",
    'spawn',
    "--workdir=$dir", '-s', 'BASE', '--', $script,
);

local %ENV = %ENV;
$ENV{YATH_IPC_DIR}          = tester_ipc_dir();
$ENV{NESTED_YATH}           = 1;
$ENV{YATH_SELF_TEST}        = 1;
$ENV{T2_HARNESS_PROC_PREFIX} = 'nested';
$ENV{TMPDIR}                = '/tmp';
$ENV{YATH_COLOR}            = 0;

my ($wfh, $rfh, $efh) = (gensym, gensym, gensym);
my $pid = open3($wfh, $rfh, $efh, @cmd);

print $wfh "first line\nsecond line\n";
close $wfh;

my $out = do { local $/; <$rfh> };
my $err = do { local $/; <$efh> };
waitpid $pid, 0;
my $exit = $? >> 8;

is($exit, 0, 'yath spawn exited 0') or diag "stderr: $err";
like($out, qr/GOT: first line/,  'stdin line 1 reached the script');
like($out, qr/GOT: second line/, 'stdin line 2 reached the script');

yath(command => 'stop', args => ["--workdir=$dir"], exit => 0);
done_testing;
