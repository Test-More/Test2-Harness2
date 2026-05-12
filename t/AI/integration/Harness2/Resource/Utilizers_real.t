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

subtest 'Memory=99%: starvation guard still runs 1 test' => sub {
    # 99% of MemTotal required free is unsatisfiable in practice. The
    # default min_concurrent=1 floor on Role::Resource::Utilizer keeps
    # the scheduler from starving: at least one test must still run.
    my $r = run_yath(['-R', 'Memory=99%'], 15);
    like($r->{stdout}, qr/PASSED/i, 'pass.t ran despite saturation (min_concurrent=1 floor)');
};

done_testing;
