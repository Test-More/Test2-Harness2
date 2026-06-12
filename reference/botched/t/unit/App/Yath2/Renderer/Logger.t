use strict;
use warnings;
use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;

BEGIN {
    my $ipcm_lib = '/home/exodist/projects/IPC-Manager/lib';
    if (-d $ipcm_lib) {
        unshift @INC, $ipcm_lib;
    }
}

use Test2::Harness2::Util::JSON qw/decode_json/;
use App::Yath2::Renderer::Logger;

my $tmpdir = tempdir(CLEANUP => 1);

# ===========================================================================
# ISA checks
# ===========================================================================

subtest 'class hierarchy' => sub {
    my $file   = File::Spec->catfile($tmpdir, 'isa_test.jsonl');
    my $logger = App::Yath2::Renderer::Logger->new(file => $file);

    isa_ok($logger, ['App::Yath2::Renderer::Logger']);
    isa_ok($logger, ['App::Yath2::Renderer']);
    isa_ok($logger, ['Test2::Harness2::Renderer']);
};

# ===========================================================================
# weight
# ===========================================================================

subtest 'weight returns -100' => sub {
    my $file   = File::Spec->catfile($tmpdir, 'weight_test.jsonl');
    my $logger = App::Yath2::Renderer::Logger->new(file => $file);
    is($logger->weight, -100, 'weight is -100');
};

# ===========================================================================
# produces_terminal_output
# ===========================================================================

subtest 'produces_terminal_output returns 0' => sub {
    my $file   = File::Spec->catfile($tmpdir, 'terminal_test.jsonl');
    my $logger = App::Yath2::Renderer::Logger->new(file => $file);
    is($logger->produces_terminal_output, 0, 'produces_terminal_output is 0');
};

# ===========================================================================
# Plain log file: start, render_event, finish
# ===========================================================================

subtest 'plain log file lifecycle' => sub {
    my $file   = File::Spec->catfile($tmpdir, 'plain.jsonl');
    my $logger = App::Yath2::Renderer::Logger->new(file => $file);

    my $ok  = eval { $logger->start; 1 };
    my $err = $@;
    ok($ok, 'start() succeeded') or diag("Error: $err");

    my @events = (
        {facet_data => {assert => {pass => 1, details => 'first'}},  job_id => 'j1'},
        {facet_data => {assert => {pass => 0, details => 'second'}}, job_id => 'j2'},
        {facet_data => {plan   => {count => 2}}, job_id => 'j1'},
    );

    for my $event (@events) {
        $ok  = eval { $logger->render_event($event); 1 };
        $err = $@;
        ok($ok, 'render_event() succeeded') or diag("Error: $err");
    }

    $ok  = eval { $logger->finish; 1 };
    $err = $@;
    ok($ok, 'finish() succeeded') or diag("Error: $err");

    ok(-f $file, 'log file exists');

    # Read and validate JSONL content
    open(my $fh, '<', $file) or die "Cannot open $file: $!";
    my @lines = <$fh>;
    close($fh);

    is(scalar @lines, 4, 'log file has 4 lines (3 events + null terminator)');

    # Validate each event line is valid JSON
    for my $i (0 .. 2) {
        chomp $lines[$i];
        my $decoded;
        $ok  = eval { $decoded = decode_json($lines[$i]); 1 };
        $err = $@;
        ok($ok,                    "line $i is valid JSON") or diag("Error: $err, line: $lines[$i]");
        ok(ref $decoded eq 'HASH', "line $i decoded to a hashref");
    }

    # Validate the null terminator
    chomp $lines[3];
    is($lines[3], 'null', 'last line is null terminator');

    # Validate content of decoded events
    my $first = decode_json($lines[0]);
    is($first->{facet_data}{assert}{details}, 'first', 'first event has correct details');
};

# ===========================================================================
# Gzip mode
# ===========================================================================

subtest 'gzip log file' => sub {
    my $ok  = eval { require IO::Compress::Gzip; 1 };
    my $err = $@;

    skip_all 'IO::Compress::Gzip not available' unless $ok;

    my $file   = File::Spec->catfile($tmpdir, 'gzip_test.jsonl.gz');
    my $logger = App::Yath2::Renderer::Logger->new(file => $file, gzip => 1);

    $ok  = eval { $logger->start; 1 };
    $err = $@;
    ok($ok, 'start() with gzip succeeded') or diag("Error: $err");

    $ok = eval {
        $logger->render_event({facet_data => {assert => {pass => 1}}, job_id => 'g1'});
        1;
    };
    $err = $@;
    ok($ok, 'render_event() with gzip succeeded') or diag("Error: $err");

    $ok  = eval { $logger->finish; 1 };
    $err = $@;
    ok($ok, 'finish() with gzip succeeded') or diag("Error: $err");

    ok(-f $file, 'gzip log file exists');
    ok(-s $file, 'gzip log file is non-empty');

    # Decompress and validate
    require IO::Uncompress::Gunzip;
    my $z    = IO::Uncompress::Gunzip->new($file) or die "Cannot open gzip: $IO::Uncompress::Gunzip::GunzipError";
    my $data = '';
    while ($z->read(my $buf, 4096)) {
        $data .= $buf;
    }
    $z->close;

    my @lines = split /\n/, $data;
    is(scalar @lines, 2, 'gzip log has 2 lines (1 event + null)');

    my $decoded;
    $ok  = eval { $decoded = decode_json($lines[0]); 1 };
    $err = $@;
    ok($ok, 'gzip line 0 is valid JSON') or diag("Error: $err");
    is($lines[1], 'null', 'gzip last line is null');
};

# ===========================================================================
# Lastlog symlink creation
# ===========================================================================

subtest 'lastlog symlink' => sub {
    # Use a subdirectory so the symlink is created there
    my $subdir = File::Spec->catdir($tmpdir, 'lastlog_test');
    mkdir($subdir) or die "Cannot create $subdir: $!";

    my $file   = File::Spec->catfile($subdir, 'run.jsonl');
    my $logger = App::Yath2::Renderer::Logger->new(file => $file, lastlog => 1);

    # chdir into the subdir so the relative lastlog symlink is created there
    my $orig_dir = Cwd::getcwd();
    require Cwd;
    chdir($subdir) or die "Cannot chdir to $subdir: $!";

    my $ok = eval {
        $logger->start;
        $logger->render_event({facet_data => {assert => {pass => 1}}, job_id => 'l1'});
        $logger->finish;
        1;
    };
    my $err = $@;

    chdir($orig_dir);

    ok($ok, 'lifecycle with lastlog succeeded') or diag("Error: $err");

    my $link = File::Spec->catfile($subdir, 'lastlog.jsonl');
    ok(-l $link, 'lastlog.jsonl symlink exists');
    ok(-f $link, 'lastlog.jsonl symlink points to an existing file');
};

# ===========================================================================
# expand_log_file_format
# ===========================================================================

subtest 'expand_log_file_format' => sub {
    # Override time_for_strftime for deterministic output
    no warnings 'redefine';
    local *App::Yath2::Renderer::Logger::time_for_strftime = sub { 1700000000 };

    my $result = App::Yath2::Renderer::Logger::expand_log_file_format('%Y-%m-%d_%!p.jsonl', undef);
    like($result, qr/^\d{4}-\d{2}-\d{2}_\d+\.jsonl$/, 'expand_log_file_format produces expected pattern');

    # %!p should be the PID
    like($result, qr/_$$\.jsonl$/, 'expand_log_file_format expands %!p to PID');

    # Unknown escape passes through
    my $unknown = App::Yath2::Renderer::Logger::expand_log_file_format('%!Z', undef);
    like($unknown, qr/%!Z/, 'unknown %! escape passes through');
};

done_testing;
