use Test2::V0;

use File::Temp qw/tempdir tempfile/;
use File::Path qw/remove_tree/;

use Test2::Harness2::Runner;

my $CLASS = 'Test2::Harness2::Runner';

# orphaned() is a pure slot check (workdir + persist file existence). Exercise it
# on a minimally-populated instance rather than standing up a real runner, whose
# init() requires a live settings object and a populated workdir.
sub mk {
    my %slots = @_;
    my $self = bless {}, $CLASS;
    $self->{$CLASS->DIR}     = $slots{dir}     if exists $slots{dir};
    $self->{$CLASS->PERSIST} = $slots{persist} if exists $slots{persist};
    $self->{$CLASS->SIGNAL}  = $slots{signal}  if exists $slots{signal};
    return $self;
}

subtest workdir_present => sub {
    my $dir = tempdir(CLEANUP => 1);
    ok(!mk(dir => $dir)->orphaned, "Not orphaned while the workdir exists");
};

subtest workdir_gone => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $r = mk(dir => $dir);
    remove_tree($dir);
    ok($r->orphaned, "Orphaned once the workdir is removed");
};

subtest persist_file_gone => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($fh, $pfile) = tempfile(UNLINK => 0);
    close($fh);

    my $r = mk(dir => $dir, persist => $pfile);
    ok(!$r->orphaned, "Not orphaned while the persistence file exists");

    unlink($pfile);
    ok($r->orphaned, "Orphaned once the persistence file is removed");
};

subtest already_signalled => sub {
    # A runner already shutting down must not be re-flagged (it is allowed to
    # finish its own teardown).
    my $r = mk(dir => '/this/path/does/not/exist', signal => 'TERM');
    ok(!$r->orphaned, "An already-signalled runner is left alone");
};

# Note: the orphaned()-drives-shutdown wiring (end_test_loop) was inlined into
# run_scheduler_only's no-preload loop in the run-path collapse (#29); orphaned()
# itself is the unit-tested primitive above.

done_testing;
