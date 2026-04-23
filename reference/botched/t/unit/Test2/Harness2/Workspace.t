use strict;
use warnings;
use Test2::V0;
use File::Spec;
use File::Temp qw/tempdir/;

use Test2::Harness2::Workspace;

# ---- Basic construction ----
subtest 'basic construction' => sub {
    my $ws = Test2::Harness2::Workspace->new();

    ok(-d $ws->root,     "root directory exists");
    ok(-d $ws->log_dir,  "log_dir exists");
    ok(-d $ws->ipcm_dir, "ipcm_dir exists");
    ok(-d $ws->tmp_dir,  "tmp_dir exists");

    like($ws->root, qr/yath2-$$-/, "root matches expected pattern");

    is($ws->log_dir,  File::Spec->catdir($ws->root, 'logs'), "log_dir is root/logs");
    is($ws->ipcm_dir, File::Spec->catdir($ws->root, 'ipcm'), "ipcm_dir is root/ipcm");
    is($ws->tmp_dir,  File::Spec->catdir($ws->root, 'tmp'),  "tmp_dir is root/tmp");

    is($ws->{Test2::Harness2::Workspace::CLEANUP()}, 0,                  "cleanup defaults to 0");
    is($ws->base_tmp,                                File::Spec->tmpdir, "base_tmp defaults to tmpdir");

    # manual cleanup
    $ws->cleanup();
    ok(!-d $ws->root, "root removed after cleanup()");
};

# ---- Custom base_tmp ----
subtest 'custom base_tmp' => sub {
    my $custom_base = tempdir(CLEANUP => 1);

    my $ws = Test2::Harness2::Workspace->new(base_tmp => $custom_base);

    ok(-d $ws->root, "root exists under custom base");

    # Verify root is inside the custom base
    my $rel = File::Spec->abs2rel($ws->root, $custom_base);
    unlike($rel, qr/^\.\./, "root is inside custom_base");

    $ws->cleanup();
    ok(!-d $ws->root, "root removed after cleanup()");
};

# ---- run_log_dir creates directory ----
subtest 'run_log_dir creates directory' => sub {
    my $ws = Test2::Harness2::Workspace->new();

    my $run_uuid = 'test-run-uuid-001';
    my $dir      = $ws->run_log_dir($run_uuid);

    ok(-d $dir, "run_log_dir created the directory");
    is($dir, File::Spec->catdir($ws->log_dir, "run_$run_uuid"), "correct path returned");

    # Calling again should be idempotent
    my $dir2 = $ws->run_log_dir($run_uuid);
    is($dir, $dir2, "run_log_dir returns same path on second call");
    ok(-d $dir2, "directory still exists on second call");

    $ws->cleanup();
};

# ---- service_log_path format ----
subtest 'service_log_path format' => sub {
    my $ws = Test2::Harness2::Workspace->new();

    my $path = $ws->service_log_path('renderer', 12345);

    is(
        $path, File::Spec->catfile($ws->log_dir, "renderer_12345.log"),
        "service_log_path returns expected path"
    );

    # Does NOT create the file
    ok(!-e $path, "service_log_path does not create the file");

    $ws->cleanup();
};

# ---- test_log_path format ----
subtest 'test_log_path format' => sub {
    my $ws = Test2::Harness2::Workspace->new();

    my $run_uuid  = 'run-abc-123';
    my $exec_uuid = 'exec-def-456';

    # Must create run dir first
    $ws->run_log_dir($run_uuid);

    my $path = $ws->test_log_path($run_uuid, $exec_uuid);

    is(
        $path,
        File::Spec->catfile($ws->log_dir, "run_$run_uuid", "$exec_uuid.jsonl"),
        "test_log_path returns expected path"
    );

    # Does NOT create the file
    ok(!-e $path, "test_log_path does not create the file");

    $ws->cleanup();
};

# ---- test_log_path dies when run dir missing ----
subtest 'test_log_path dies when run dir missing' => sub {
    my $ws = Test2::Harness2::Workspace->new();

    my $ok  = eval { $ws->test_log_path('no-such-run', 'some-exec'); 1 };
    my $err = $@;

    ok(!$ok, "test_log_path dies when run dir does not exist");
    like($err, qr/does not exist/, "error mentions does not exist");

    $ws->cleanup();
};

# ---- cleanup removes root ----
subtest 'cleanup removes root' => sub {
    my $ws = Test2::Harness2::Workspace->new();

    my $root = $ws->root;
    ok(-d $root, "root exists before cleanup");

    # Create a nested file to verify deep removal
    $ws->run_log_dir('some-run');
    my $nested = File::Spec->catfile($ws->log_dir, 'run_some-run', 'test.jsonl');
    open my $fh, '>', $nested or die "Cannot write test file: $!";
    print $fh "test\n";
    close $fh;
    ok(-f $nested, "nested file exists before cleanup");

    $ws->cleanup();

    ok(!-d $root,   "root removed after cleanup()");
    ok(!-f $nested, "nested file also removed");
};

# ---- DESTROY auto-cleanup when cleanup flag set ----
subtest 'DESTROY auto-cleanup' => sub {
    my $root;
    {
        my $ws = Test2::Harness2::Workspace->new(cleanup => 1);
        $root = $ws->root;
        ok(-d $root, "root exists before scope exit");
        # $ws goes out of scope here, DESTROY should clean up
    }
    ok(!-d $root, "root removed by DESTROY when cleanup => 1");
};

# ---- DESTROY does NOT auto-cleanup when cleanup flag is 0 ----
subtest 'DESTROY does not cleanup when cleanup => 0' => sub {
    my $root;
    {
        my $ws = Test2::Harness2::Workspace->new(cleanup => 0);
        $root = $ws->root;
        ok(-d $root, "root exists before scope exit");
    }
    ok(-d $root, "root still exists after DESTROY when cleanup => 0");

    # manual cleanup
    require File::Path;
    File::Path::remove_tree($root, {safe => 1});
    ok(!-d $root, "root removed manually");
};

done_testing;
