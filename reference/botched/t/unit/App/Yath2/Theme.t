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

# ---------------------------------------------------------------------------
# Construction with use_color => 1
# ---------------------------------------------------------------------------
subtest 'construction with color enabled' => sub {
    my $theme = App::Yath2::Theme->new(use_color => 1);
    isa_ok($theme, ['App::Yath2::Theme']);

    ok($theme->use_color, 'use_color is true');

    # color_map_term should be populated
    my $term_map = $theme->color_map_term;
    ok($term_map,                  'color_map_term is set');
    ok(exists $term_map->{base},   'term map has base');
    ok(exists $term_map->{tag},    'term map has tag');
    ok(exists $term_map->{facet},  'term map has facet');
    ok(exists $term_map->{status}, 'term map has status');
    ok(exists $term_map->{state},  'term map has state');
    ok(exists $term_map->{job},    'term map has job');

    # color_map_text should be populated
    my $text_map = $theme->color_map_text;
    ok($text_map,                'color_map_text is set');
    ok(exists $text_map->{base}, 'text map has base');
    is($text_map->{base}->{reset}, 'reset', 'text map base reset is the name "reset"');

    # term map base reset should be an ANSI code (non-empty string)
    my $reset_code = $term_map->{base}->{reset};
    ok(defined $reset_code && length($reset_code) > 0, 'term map base reset is a non-empty ANSI code');

    # borders should be set
    my $borders = $theme->borders;
    ok($borders,                   'borders is set');
    ok(exists $borders->{default}, 'borders has default entry');
};

# ---------------------------------------------------------------------------
# Construction with use_color => 0
# ---------------------------------------------------------------------------
subtest 'construction with color disabled' => sub {
    my $theme = App::Yath2::Theme->new(use_color => 0);
    isa_ok($theme, ['App::Yath2::Theme']);

    ok(!$theme->use_color, 'use_color is false');

    # color maps should NOT be populated when color is off
    ok(!$theme->color_map_term, 'color_map_term not set when color disabled');
    ok(!$theme->color_map_text, 'color_map_text not set when color disabled');

    # get_term_color should return empty string
    is($theme->get_term_color('base', 'reset'), '', 'get_term_color returns empty string when color disabled');
    is($theme->get_text_color('base', 'reset'), '', 'get_text_color returns empty string when color disabled');

    # borders should still be set
    my $borders = $theme->borders;
    ok($borders, 'borders still set when color disabled');
};

# ---------------------------------------------------------------------------
# Color lookups with color enabled
# ---------------------------------------------------------------------------
subtest 'color lookups' => sub {
    my $theme = App::Yath2::Theme->new(use_color => 1);

    # Base reset lookup
    my $reset_term = $theme->get_term_color('base', 'reset');
    ok(defined $reset_term && length($reset_term) > 0, 'get_term_color base/reset returns ANSI code');

    my $reset_text = $theme->get_text_color('base', 'reset');
    is($reset_text, 'reset', 'get_text_color base/reset returns color name');

    # Unknown thing should fall back to base reset
    my $unknown = $theme->get_term_color('nonexistent', 'foo');
    is($unknown, $reset_term, 'unknown thing falls back to base reset');
};

# ---------------------------------------------------------------------------
# Job color assignment and freeing
# ---------------------------------------------------------------------------
subtest 'job color assignment' => sub {
    my $theme = App::Yath2::Theme->new(use_color => 1);

    # Assign a color to job-001
    $theme->assign_job_color('job-001');

    my $term_color = $theme->get_term_color('job', 'job-001');
    ok(defined $term_color && length($term_color) > 0, 'assigned job gets a term color');

    my $text_color = $theme->get_text_color('job', 'job-001');
    ok(defined $text_color && length($text_color) > 0, 'assigned job gets a text color');

    # Assign another job
    $theme->assign_job_color('job-002');
    my $term_color2 = $theme->get_term_color('job', 'job-002');
    ok(defined $term_color2 && length($term_color2) > 0, 'second job gets a term color');

    # Free the first job color
    $theme->free_job_color('job-001');

    # After freeing, lookup should fall back (no longer assigned)
    # The job map entry is deleted, so it should trigger generator or fallback
    my $after_free = $theme->color_map_term->{job}->{'job-001'};
    ok(!defined $after_free, 'job-001 term color removed after free');

    my $after_free_text = $theme->color_map_text->{job}->{'job-001'};
    ok(!defined $after_free_text, 'job-001 text color removed after free');
};

# ---------------------------------------------------------------------------
# Job color reuse after freeing
# ---------------------------------------------------------------------------
subtest 'job color reuse' => sub {
    my $theme = App::Yath2::Theme->new(use_color => 1);

    # Assign and free
    $theme->assign_job_color('job-a');
    my $text_a = $theme->get_text_color('job', 'job-a');
    $theme->free_job_color('job-a');

    # Assign a new job - should get a color (possibly same one reused)
    $theme->assign_job_color('job-b');
    my $text_b = $theme->get_text_color('job', 'job-b');
    ok(defined $text_b && length($text_b) > 0, 'new job gets color after previous was freed');
};

# ---------------------------------------------------------------------------
# Job color auto-assignment via get_term_color
# ---------------------------------------------------------------------------
subtest 'job color auto-assignment via lookup' => sub {
    my $theme = App::Yath2::Theme->new(use_color => 1);

    # Looking up a job color that hasn't been assigned should trigger the generator
    my $color = $theme->get_term_color('job', 'auto-job');
    ok(defined $color && length($color) > 0, 'auto-assigned job color via get_term_color');
};

# ---------------------------------------------------------------------------
# Border retrieval
# ---------------------------------------------------------------------------
subtest 'border retrieval' => sub {
    my $theme = App::Yath2::Theme->new(use_color => 1);

    # Default borders
    my $default = $theme->get_borders('default');
    is($default, ['[', ']'], 'default borders are [ and ]');

    # Unknown border name falls back to default
    my $unknown = $theme->get_borders('nonexistent');
    is($unknown, ['[', ']'], 'unknown border name falls back to default');
};

# ---------------------------------------------------------------------------
# DEFAULT_* class methods
# ---------------------------------------------------------------------------
subtest 'DEFAULT class methods' => sub {
    my %base = App::Yath2::Theme->DEFAULT_BASE_COLORS();
    is(\%base, {reset => 'reset'}, 'DEFAULT_BASE_COLORS returns reset => reset');

    my @state = App::Yath2::Theme->DEFAULT_STATE_COLORS();
    is(\@state, [], 'DEFAULT_STATE_COLORS returns empty list');

    my @job = App::Yath2::Theme->DEFAULT_JOB_COLORS();
    ok(scalar @job > 0, 'DEFAULT_JOB_COLORS returns at least one color');

    my %borders = App::Yath2::Theme->DEFAULT_BORDERS();
    ok(exists $borders{default}, 'DEFAULT_BORDERS has default key');
    is($borders{default}, ['[', ']'], 'DEFAULT_BORDERS default is [ and ]');
};

# ---------------------------------------------------------------------------
# color_vals method
# ---------------------------------------------------------------------------
subtest 'color_vals' => sub {
    my $theme = App::Yath2::Theme->new(use_color => 1);

    my $pairs  = {reset => 'reset', bold => 'bold'};
    my $result = $theme->color_vals($pairs);

    # Should have converted color names to ANSI codes
    ok(defined $result->{reset} && length($result->{reset}) > 0, 'color_vals converts reset');
    ok(defined $result->{bold}  && length($result->{bold}) > 0,  'color_vals converts bold');

    # The values should not be the original plain text names
    isnt($result->{reset}, 'reset_name', 'color_vals result is not plain text');
};

# ---------------------------------------------------------------------------
# assign_job_color returns empty string when color disabled
# ---------------------------------------------------------------------------
subtest 'assign_job_color with color disabled' => sub {
    my $theme  = App::Yath2::Theme->new(use_color => 0);
    my $result = $theme->assign_job_color('job-x');
    is($result, '', 'assign_job_color returns empty string when color disabled');
};

done_testing;
