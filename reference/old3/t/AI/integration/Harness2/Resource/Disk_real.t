use Test2::V0;
use Test2::Require::AuthorTesting;

use File::Temp qw/tempdir/;
use File::Basename qw/dirname/;
use File::Spec ();
use IPC::Cmd qw/run/;

skip_all "Filesys::Df not installed" unless eval { require Filesys::Df; 1 };

my $repo = File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), '..', '..', '..', '..'));
my $lib  = File::Spec->catdir($repo, 'lib');
die "Cannot locate repo lib at $lib" unless -d $lib;

my $fixture_dir = tempdir(CLEANUP => 1);

# Tiny passing test fixture.
open my $fh, '>', "$fixture_dir/pass.t" or die "open: $!";
print {$fh} <<'PERL';
use Test2::V0;
ok(1, 'pass');
done_testing;
PERL
close $fh;

sub run_yath {
    my ($args, $timeout) = @_;
    my $cmd = ['yath', '-D', 'test', '-j1', @$args, "$fixture_dir/pass.t"];
    local $ENV{PERL5LIB} = join(
        ':',
        $lib,
        (defined $ENV{PERL5LIB} ? ($ENV{PERL5LIB}) : ()),
    );
    my ($ok, $err, $full, $stdout, $stderr) = run(
        command => $cmd,
        timeout => $timeout // 60,
    );
    return {
        ok     => $ok ? 1 : 0,
        stdout => join('', @$stdout),
        stderr => join('', @$stderr),
    };
}

subtest 'trivially-satisfied disk threshold lets tests run' => sub {
    my $r = run_yath(['-R', 'Disk=/tmp:1kb']);
    ok($r->{ok}, 'yath run succeeded') or diag $r->{stderr};
    like($r->{stdout}, qr/PASSED/i, 'pass.t ran');
};

subtest 'always-deferring disk threshold defers all tests' => sub {
    # Require 100TB free on /tmp -- larger than any realistic
    # filesystem. A byte-based threshold is more robust than a
    # percentage one because tmpfs and other in-memory filesystems
    # routinely report very high free-percentage even when small.
    # Time-bound the run so the deferred case cannot run forever.
    my $r = run_yath(['-R', 'Disk=/tmp:100tb'], 15);
    # The harness will exit non-zero (timeout) or report no test
    # progress -- either way the fixture must NOT have produced a
    # PASSED line.
    unlike($r->{stdout}, qr/PASSED/i, 'pass.t did NOT run')
        or diag "stdout: $r->{stdout}\nstderr: $r->{stderr}";
};

done_testing;
