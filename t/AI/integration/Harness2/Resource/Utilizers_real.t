use Test2::V0;
use Test2::Require::AuthorTesting;

use File::Temp qw/tempdir/;
use Time::HiRes qw/time/;
use IPC::Cmd qw/run/;
use Cwd qw/getcwd/;

plan skip_all => "Linux only" unless $^O eq 'linux';

my $repo        = getcwd();
my $fixture_dir = tempdir(CLEANUP => 1);

open my $fh, '>', "$fixture_dir/pass.t" or die "open: $!";
print {$fh} <<'PERL';
use Test2::V0;
ok(1, 'pass');
done_testing;
PERL
close $fh;

sub run_yath {
    my ($args, $timeout) = @_;
    local $ENV{PERL5LIB} = "$repo/lib" . (defined $ENV{PERL5LIB} ? ":$ENV{PERL5LIB}" : '');
    my $cmd = ['yath', '-D', 'test', '-j1', @$args, "$fixture_dir/pass.t"];
    my $t0  = time;
    my ($ok, $err, $full, $stdout, $stderr) = run(
        command => $cmd,
        timeout => $timeout // 60,
    );
    return {
        ok     => $ok ? 1 : 0,
        wall   => time - $t0,
        stdout => join('', @$stdout),
        stderr => join('', @$stderr),
    };
}

subtest 'Memory=1kb: trivially satisfied, test runs' => sub {
    my $r = run_yath(['-R', 'Memory=1kb']);
    ok($r->{ok}, 'yath run succeeded') or diag $r->{stderr};
    like($r->{stdout}, qr/PASSED/i, 'pass.t ran');
};

subtest 'Memory=99%: defers' => sub {
    # 99% of MemTotal required free -- vanishingly rare. Timeout short.
    my $r = run_yath(['-R', 'Memory=99%'], 15);
    unlike($r->{stdout}, qr/PASSED/i, 'pass.t did NOT run');
};

done_testing;
