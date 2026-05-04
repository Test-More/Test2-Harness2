use Test2::V0;
use File::Temp qw/tempdir/;

# Verify the harness's top-level Service collector creates a LIVE
# sentinel under <logdir>/LIVE on init and removes it on clean exit
# (per F19 / F20). Non-top-level collectors must NOT create a LIVE
# file.

use lib 't/lib';
use Test2::Harness2::Collector;

my $dir = tempdir(CLEANUP => 1);

# Build a barebones collector instance just enough to call the
# sentinel helpers. We bypass spawn() entirely -- the helpers do
# their work through file-system side effects we can verify directly.
sub mk {
    my %args = @_;
    return Test2::Harness2::Collector->new(
        type        => 'Service',
        id          => 'harness',
        logdir      => $dir,
        ipcm_info   => 'fake-ipcm',
        ipc_harness => 'harness',
        out_fh      => \*STDIN,    # placeholder; we never collect
        %args,
    );
}

subtest 'top-level harness collector drops LIVE on init, removes on clean exit' => sub {
    my $c = mk(ipc_parent => undef, ipc_run => undef);
    ok($c->_is_top_level_harness, 'top-level harness identified by ipc_parent+ipc_run undef');

    ok(! -e "$dir/LIVE", 'LIVE absent before _create_live_sentinel');
    $c->_create_live_sentinel;
    ok(-e "$dir/LIVE", 'LIVE created');

    open(my $fh, '<', "$dir/LIVE") or die "open: $!";
    my $body = do { local $/; <$fh> };
    is($body, "1\n", 'LIVE content is "1\\n"');

    $c->_remove_live_sentinel;
    ok(! -e "$dir/LIVE", 'LIVE removed by _remove_live_sentinel');
};

subtest 'non-top-level collector does NOT create LIVE' => sub {
    my $sub = tempdir(CLEANUP => 1);
    my $c = Test2::Harness2::Collector->new(
        type        => 'Job',
        id          => 0,
        run_id      => 0,
        job_try     => 0,
        logdir      => $sub,
        ipcm_info   => 'fake-ipcm',
        ipc_parent  => 'run-0',
        ipc_run     => 'run-0',
        ipc_harness => 'harness',
        out_fh      => \*STDIN,
    );
    ok(!$c->_is_top_level_harness, 'job collector is not top-level');

    $c->_create_live_sentinel;
    ok(! -e "$sub/LIVE", 'no LIVE created for non-top-level collector');
};

subtest 'creating LIVE is idempotent' => sub {
    my $c = mk(ipc_parent => undef, ipc_run => undef);

    # Pre-existing LIVE file should not be replaced.
    open my $fh, '>', "$dir/LIVE" or die $!;
    print $fh "preexisting\n";
    close $fh;

    $c->_create_live_sentinel;

    open(my $check, '<', "$dir/LIVE") or die $!;
    my $body = do { local $/; <$check> };
    is($body, "preexisting\n", '_create_live_sentinel does not overwrite an existing LIVE');

    unlink "$dir/LIVE";
};

done_testing;
