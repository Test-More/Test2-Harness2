use strict;
use warnings;
use Test2::V0;

BEGIN {
    my $ipcm_lib = '/home/exodist/projects/IPC-Manager/lib';
    if (-d $ipcm_lib) {
        unshift @INC, $ipcm_lib;
    }
}

use App::Yath2::Theme;
use App::Yath2::Renderer::Default;

# Build a theme with color disabled so output is predictable
my $theme = App::Yath2::Theme->new(use_color => 0);

# Capture output to a string via an in-memory filehandle
my $output = '';
open(my $io, '>', \$output) or die "Cannot open in-memory filehandle: $!";

my $renderer = App::Yath2::Renderer::Default->new(
    theme    => $theme,
    io       => $io,
    color    => 0,
    verbose  => 1,
    tty      => 0,
    progress => 0,
    settings => {},
);

isa_ok($renderer, ['App::Yath2::Renderer::Default']);
isa_ok($renderer, ['App::Yath2::Renderer']);
isa_ok($renderer, ['Test2::Harness2::Renderer']);

# ===========================================================================
# produces_terminal_output
# ===========================================================================

subtest 'produces_terminal_output returns 1' => sub {
    is($renderer->produces_terminal_output, 1, 'produces_terminal_output is true');
};

# ===========================================================================
# weight
# ===========================================================================

subtest 'weight returns 0' => sub {
    is($renderer->weight, 0, 'weight is 0');
};

# ===========================================================================
# Rendering an assert event
# ===========================================================================

subtest 'render assert event produces output' => sub {
    $output = '';

    my $event = {
        facet_data => {
            assert  => {pass   => 1, details => 'test assertion ok'},
            trace   => {frame  => ['main', 'test.t', 42, 'main::foo']},
            harness => {job_id => 'job-1'},
        },
        job_id => 'job-1',
    };

    $renderer->render_event($event);

    ok(length($output) > 0, 'output was produced for assert event');
    like($output, qr/PASS/,              'output contains PASS tag');
    like($output, qr/test assertion ok/, 'output contains assert details');
};

# ===========================================================================
# Rendering a plan event
# ===========================================================================

subtest 'render plan event produces output' => sub {
    $output = '';

    my $event = {
        facet_data => {
            plan    => {count  => 5},
            harness => {job_id => 'job-1'},
        },
        job_id => 'job-1',
    };

    $renderer->render_event($event);

    ok(length($output) > 0, 'output was produced for plan event');
    like($output, qr/PLAN/,                   'output contains PLAN tag');
    like($output, qr/Expected assertions: 5/, 'output contains plan count');
};

# ===========================================================================
# Rendering a harness_job_launch event
# ===========================================================================

subtest 'render harness_job_launch event produces output' => sub {
    $output = '';

    my $event = {
        facet_data => {
            harness_job_launch => {retry => 0},
            harness_job        => {
                job_id    => 'job-2',
                file      => '/tmp/t/foo.t',
                test_file => {file => '/tmp/t/foo.t'},
            },
            harness => {job_id => 'job-2'},
        },
        job_id => 'job-2',
    };

    # Enable show_job_launch to see output
    $renderer->{show_job_launch} = 1;
    $renderer->render_event($event);
    $renderer->{show_job_launch} = 0;

    ok(length($output) > 0, 'output was produced for job launch event');
    like($output, qr/LAUNCH/, 'output contains LAUNCH tag');
};

# ===========================================================================
# Verbose vs quiet output differences
# ===========================================================================

subtest 'verbose vs quiet output' => sub {
    # Verbose mode (default for our renderer)
    $output = '';
    my $verbose_renderer = App::Yath2::Renderer::Default->new(
        theme    => $theme,
        io       => $io,
        color    => 0,
        verbose  => 1,
        tty      => 0,
        progress => 0,
        settings => {},
    );

    my $event = {
        facet_data => {
            assert  => {pass   => 0, details => 'failing test'},
            trace   => {frame  => ['main', 'test.t', 99, 'main::foo']},
            harness => {job_id => 'job-3'},
        },
        job_id => 'job-3',
    };

    $verbose_renderer->render_event($event);
    my $verbose_out = $output;

    # Quiet mode
    $output = '';
    my $quiet_renderer = App::Yath2::Renderer::Default->new(
        theme    => $theme,
        io       => $io,
        color    => 0,
        verbose  => 0,
        tty      => 0,
        progress => 0,
        settings => {},
    );

    $quiet_renderer->render_event($event);
    my $quiet_out = $output;

    ok(length($verbose_out) > 0, 'verbose output is non-empty');
    ok(length($quiet_out) > 0,   'quiet output is non-empty for failing test');

    # Verbose output includes debug line, quiet does too for failures,
    # but verbose should generally be longer
    like($verbose_out, qr/FAIL/,  'verbose output shows FAIL');
    like($quiet_out,   qr/FAIL/,  'quiet output shows FAIL for failing test');
    like($verbose_out, qr/DEBUG/, 'verbose output includes DEBUG line');
};

subtest 'quiet mode suppresses passing asserts' => sub {
    $output = '';
    my $quiet_renderer = App::Yath2::Renderer::Default->new(
        theme    => $theme,
        io       => $io,
        color    => 0,
        verbose  => 0,
        tty      => 0,
        progress => 0,
        settings => {},
    );

    my $event = {
        facet_data => {
            assert  => {pass   => 1, details => 'passing test'},
            harness => {job_id => 'job-4'},
        },
        job_id => 'job-4',
    };

    $quiet_renderer->render_event($event);

    # In quiet mode, passing tests produce no output
    is($output, '', 'quiet mode produces no output for passing assert');
};

# ===========================================================================
# build_line
# ===========================================================================

subtest 'build_line formats output' => sub {
    my @lines = $renderer->build_line('job 1 | ', 'assert', 'PASS', 'test ok');
    ok(@lines >= 1, 'build_line returns at least one line');
    like($lines[0], qr/PASS/,    'line contains tag');
    like($lines[0], qr/test ok/, 'line contains text');
};

# ===========================================================================
# render_tree
# ===========================================================================

subtest 'render_tree produces tree prefix' => sub {
    my $f = {
        harness => {job_id => 'job-5'},
        trace   => {frame  => ['main', 'test.t', 1, 'main::foo']},
    };

    my $tree = $renderer->render_tree($f);
    ok(defined $tree && length($tree) > 0, 'render_tree returns non-empty string');
    like($tree, qr/job/, 'tree contains job prefix');
};

# ===========================================================================
# reset and colorstrip
# ===========================================================================

subtest 'reset returns reset color code' => sub {
    my $reset = $renderer->reset;
    # With use_color => 0, get_term_color returns ''
    is($reset, '', 'reset returns empty string when color is off');
};

subtest 'colorstrip removes ANSI codes' => sub {
    my $str = $renderer->colorstrip("plain text");
    is($str, 'plain text', 'plain text passes through');
};

# ===========================================================================
# finish cleans up
# ===========================================================================

subtest 'finish does not die' => sub {
    $output = '';
    my $ok  = eval { $renderer->finish; 1 };
    my $err = $@;
    ok($ok, "finish does not die") or diag("Error: $err");
};

# ===========================================================================
# io method
# ===========================================================================

subtest 'io returns correct filehandle' => sub {
    my $default_io = $renderer->io(undef);
    ok($default_io, 'io(undef) returns the default io');

    my $job_io = $renderer->io('nonexistent-job');
    ok($job_io, 'io(job_id) returns fallback io');
};

done_testing;
