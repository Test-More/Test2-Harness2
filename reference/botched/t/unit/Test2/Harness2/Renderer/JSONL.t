use Test2::V0;
use File::Temp qw/tempfile/;

use Test2::Harness2::Event;
use Test2::Harness2::Renderer;
use Test2::Harness2::Renderer::JSONL;
use Test2::Harness2::Util::JSON qw/decode_json/;

# ---- produces_terminal_output ----
subtest 'produces_terminal_output is false' => sub {
    my $r = Test2::Harness2::Renderer::JSONL->new();
    ok(!$r->produces_terminal_output, "produces_terminal_output is false");
};

# ---- has_render_event is true for JSONL ----
subtest 'has_render_event is true for JSONL' => sub {
    ok(
        Test2::Harness2::Renderer::has_render_event('Test2::Harness2::Renderer::JSONL'),
        "has_render_event returns true for JSONL renderer"
    );
};

# ---- isa check ----
subtest 'JSONL isa Renderer' => sub {
    my $r = Test2::Harness2::Renderer::JSONL->new();
    isa_ok($r, 'Test2::Harness2::Renderer');
};

# ---- write events to JSONL and verify content ----
subtest 'write events to JSONL file' => sub {
    my ($fh, $filename) = tempfile(UNLINK => 1);
    close $fh;

    my $renderer = Test2::Harness2::Renderer::JSONL->new(log_file => $filename);

    $renderer->start(log_file => $filename, per_test => 1);

    my $e1 = Test2::Harness2::Event->new(
        facet_data => {assert => {pass => 1, details => 'ok 1'}},
        run_id     => 'run-1',
        job_id     => 'job-1',
        job_try    => 0,
    );

    my $e2 = Test2::Harness2::Event->new(
        facet_data => {info => [{tag => 'NOTE', details => 'a note'}]},
        run_id     => 'run-1',
        job_id     => 'job-1',
        job_try    => 0,
    );

    $renderer->render_event($e1);
    $renderer->render_event($e2);

    $renderer->finish(log_file => $filename, per_test => 1);

    open(my $in, '<', $filename) or die "Cannot open $filename: $!";
    my @lines = <$in>;
    close $in;

    is(scalar @lines, 2, "two lines written to JSONL file");

    my $decoded1 = decode_json($lines[0]);
    ok($decoded1, "first line is valid JSON");
    is($decoded1->{job_id},                   'job-1', "first event job_id round-trips");
    is($decoded1->{facet_data}{assert}{pass}, 1,       "first event assert.pass round-trips");

    my $decoded2 = decode_json($lines[1]);
    ok($decoded2, "second line is valid JSON");
    is($decoded2->{facet_data}{info}[0]{tag}, 'NOTE', "second event info.tag round-trips");
};

# ---- start opens fh, finish closes it ----
subtest 'start/finish lifecycle' => sub {
    my ($fh, $filename) = tempfile(UNLINK => 1);
    close $fh;

    my $renderer = Test2::Harness2::Renderer::JSONL->new(log_file => $filename);

    ok(!$renderer->fh, "fh not set before start");

    $renderer->start();

    ok($renderer->fh, "fh is set after start");

    $renderer->finish();

    # After finish the fh should be closed/cleared
    ok(!$renderer->fh, "fh cleared after finish");
};

# ---- render_event uses as_json when available ----
subtest 'render_event uses as_json when available' => sub {
    my ($fh, $filename) = tempfile(UNLINK => 1);
    close $fh;

    my $renderer = Test2::Harness2::Renderer::JSONL->new(log_file => $filename);
    $renderer->start();

    my $e = Test2::Harness2::Event->new(
        facet_data => {assert => {pass => 1, details => 'cached'}},
        run_id     => 'run-2',
        job_id     => 'job-2',
        job_try    => 0,
    );

    # Pre-cache json so we know which path is taken
    my $expected_json = $e->as_json();

    $renderer->render_event($e);
    $renderer->finish();

    open(my $in, '<', $filename) or die "Cannot open $filename: $!";
    my $line = <$in>;
    close $in;

    chomp $line;
    is($line, $expected_json, "render_event uses cached as_json output");
};

done_testing;
