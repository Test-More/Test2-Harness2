use strict;
use warnings;
use Test2::V0;

BEGIN {
    my $ipcm_lib = '/home/exodist/projects/IPC-Manager/lib';
    if (-d $ipcm_lib) {
        unshift @INC, $ipcm_lib;
    }
}

use App::Yath2::Renderer::Default::Composer;

my $comp = App::Yath2::Renderer::Default::Composer->new();
isa_ok($comp, ['App::Yath2::Renderer::Default::Composer']);

# ===========================================================================
# render_one_line
# ===========================================================================

subtest 'render_one_line - assert pass' => sub {
    my $f = {
        assert => {pass => 1, details => 'test passed'},
    };
    my $out = $comp->render_one_line($f);
    is($out, ['assert', 'PASS', 'test passed'], 'pass renders correctly');
};

subtest 'render_one_line - assert fail' => sub {
    my $f = {
        assert => {pass => 0, details => 'test failed'},
    };
    my $out = $comp->render_one_line($f);
    is($out, ['assert', 'FAIL', 'test failed'], 'fail renders correctly');
};

subtest 'render_one_line - plan' => sub {
    my $f = {
        plan => {count => 5},
    };
    my $out = $comp->render_one_line($f);
    is($out, ['plan', 'PLAN', 'Expected assertions: 5'], 'plan renders correctly');
};

subtest 'render_one_line - halt' => sub {
    my $f = {
        control => {halt => 1, details => 'Bail out!'},
    };
    my $out = $comp->render_one_line($f);
    is($out, ['control', 'HALT', 'Bail out!'], 'halt renders correctly');
};

subtest 'render_one_line - info' => sub {
    my $f = {
        info => [{tag => 'DIAG', details => 'some diagnostics'}],
    };
    my $out = $comp->render_one_line($f);
    is($out, ['info', 'DIAG', 'some diagnostics'], 'info renders correctly');
};

subtest 'render_one_line - error' => sub {
    my $f = {
        errors => [{details => 'something broke', fail => 1}],
    };
    my $out = $comp->render_one_line($f);
    is($out, ['error', 'FATAL', 'something broke'], 'error renders correctly');
};

subtest 'render_one_line - custom render facet' => sub {
    my $f = {
        render => [{facet => 'custom', tag => 'mytag', details => 'custom line'}],
    };
    my $out = $comp->render_one_line($f);
    is($out, ['custom', 'MYTAG', 'custom line'], 'custom render facet used first');
};

subtest 'render_one_line - priority halt over assert' => sub {
    my $f = {
        control => {halt => 1, details => 'Bail out!'},
        assert  => {pass => 1, details => 'test passed'},
    };
    my $out = $comp->render_one_line($f);
    is($out, ['control', 'HALT', 'Bail out!'], 'halt takes priority over assert');
};

subtest 'render_one_line - returns undef for empty facet data' => sub {
    my $f   = {};
    my $out = $comp->render_one_line($f);
    ok(!defined $out, 'returns undef for empty facet data');
};

# ===========================================================================
# render_verbose
# ===========================================================================

subtest 'render_verbose - assert with info' => sub {
    my $f = {
        assert => {pass  => 0, details => 'failing test'},
        trace  => {frame => ['main', 'test.t', 42, 'main::foo']},
        info   => [{tag => 'DIAG', details => 'expected 1 got 2'}],
    };
    my $out = $comp->render_verbose($f);
    ok(ref $out eq 'ARRAY', 'returns arrayref');
    ok(@$out >= 3,          'at least 3 components: assert + debug + info');
    is($out->[0], ['assert', 'FAIL',  'failing test'],     'assert component');
    is($out->[1], ['trace',  'DEBUG', 'test.t line 42'],   'debug component');
    is($out->[2], ['info',   'DIAG',  'expected 1 got 2'], 'info component');
};

subtest 'render_verbose - passing assert omits debug' => sub {
    my $f = {
        assert => {pass  => 1, details => 'good test'},
        trace  => {frame => ['main', 'test.t', 10, 'main::foo']},
    };
    my $out = $comp->render_verbose($f);
    is(scalar @$out, 1,                               'only assert, no debug for passing test');
    is($out->[0],    ['assert', 'PASS', 'good test'], 'assert pass component');
};

subtest 'render_verbose - multiple components' => sub {
    my $f = {
        plan   => {count => 3},
        assert => {pass  => 1, details => 'ok'},
    };
    my $out = $comp->render_verbose($f);
    ok(@$out >= 2, 'at least plan + assert');
    is($out->[0], ['plan',   'PLAN', 'Expected assertions: 3'], 'plan first');
    is($out->[1], ['assert', 'PASS', 'ok'],                     'assert second');
};

subtest 'render_verbose - amnesty on failing assert' => sub {
    my $f = {
        assert  => {pass => 0, details => 'todo test'},
        amnesty => [{tag => 'TODO', details => 'not yet implemented'}],
        trace   => {frame => ['main', 'test.t', 5, 'main::foo']},
    };
    my $out = $comp->render_verbose($f);
    ok(@$out >= 2, 'at least assert + amnesty');
    is($out->[0], ['assert', '! PASS !', 'todo test'], 'amnestied assert');
    # No debug because amnesty means pass
    # Wait - amnesty does NOT set pass, but render_verbose checks pass || no_debug
    # assert->{pass} is 0, no_debug is undef, so debug IS rendered
    is($out->[1], ['trace',   'DEBUG', 'test.t line 5'],       'debug rendered for failing todo');
    is($out->[2], ['amnesty', 'TODO',  'not yet implemented'], 'amnesty component');
};

subtest 'render_verbose - custom render facet overrides' => sub {
    my $f = {
        render => [
            {facet => 'custom', tag => 'note', details => 'line one'},
            {facet => 'custom', tag => 'note', details => 'line two'},
        ],
    };
    my $out = $comp->render_verbose($f);
    is(
        $out, [
            ['custom', 'NOTE', 'line one'],
            ['custom', 'NOTE', 'line two'],
        ],
        'custom render facet produces all lines'
    );
};

subtest 'render_verbose - about fallback when nothing else' => sub {
    my $f = {
        about => {details => 'Some event', package => 'Test2::Event::Generic'},
    };
    my $out = $comp->render_verbose($f);
    is($out, [['about', 'Generic', 'Some event']], 'about with package extracts short name');
};

subtest 'render_verbose - about without package' => sub {
    my $f = {
        about => {details => 'Unknown event'},
    };
    my $out = $comp->render_verbose($f);
    is($out, [['about', 'ABOUT', 'Unknown event']], 'about without package uses ABOUT tag');
};

subtest 'render_verbose - control halt' => sub {
    my $f = {
        control => {halt => 1, details => 'Bail out!'},
    };
    my $out = $comp->render_verbose($f);
    is($out, [['control', 'HALT', 'Bail out!']], 'halt in verbose mode');
};

# ===========================================================================
# render_brief
# ===========================================================================

subtest 'render_brief - filters to critical tags only (render facet)' => sub {
    my $f = {
        render => [
            {facet => 'info',  tag => 'NOTE',     details => 'should be filtered out'},
            {facet => 'info',  tag => 'DIAG',     details => 'diagnostic kept'},
            {facet => 'info',  tag => 'STDERR',   details => 'stderr kept'},
            {facet => 'error', tag => 'whatever', details => 'error facet kept'},
        ],
    };
    my $out = $comp->render_brief($f);
    is(
        $out, [
            ['info',  'DIAG',     'diagnostic kept'],
            ['info',  'STDERR',   'stderr kept'],
            ['error', 'WHATEVER', 'error facet kept'],
        ],
        'brief filters to critical tags and facets'
    );
};

subtest 'render_brief - failing assert without amnesty' => sub {
    my $f = {
        assert => {pass  => 0, details => 'broken test'},
        trace  => {frame => ['main', 'test.t', 99, 'main::foo']},
    };
    my $out = $comp->render_brief($f);
    ok(@$out >= 2, 'assert + debug');
    is($out->[0], ['assert', 'FAIL',  'broken test'],    'failing assert in brief');
    is($out->[1], ['trace',  'DEBUG', 'test.t line 99'], 'debug in brief');
};

subtest 'render_brief - passing assert omitted' => sub {
    my $f = {
        assert => {pass => 1, details => 'good test'},
    };
    my $out = $comp->render_brief($f);
    is($out, [], 'passing assert not shown in brief');
};

subtest 'render_brief - failing assert with amnesty omitted' => sub {
    my $f = {
        assert  => {pass => 0, details => 'todo test'},
        amnesty => [{tag => 'TODO', details => 'wip'}],
    };
    my $out = $comp->render_brief($f);
    is($out, [], 'amnestied failing assert not shown in brief');
};

subtest 'render_brief - info filters to debug/important/peek' => sub {
    my $f = {
        info => [
            {tag => 'NOTE', details => 'normal note',    debug     => 0},
            {tag => 'DIAG', details => 'debug diag',     debug     => 1},
            {tag => 'NOTE', details => 'important note', important => 1},
            {tag => 'PEEK', details => 'peeking',        peek      => 1},
        ],
    };
    my $out = $comp->render_brief($f);
    is(scalar @$out, 3, 'three info items kept');
    is($out->[0],    ['info', 'DIAG', 'debug diag'],     'debug info kept');
    is($out->[1],    ['info', 'NOTE', 'important note'], 'important info kept');
    is($out->[2],    ['info', 'PEEK', 'peeking'],        'peek info kept');
};

subtest 'render_brief - errors always shown' => sub {
    my $f = {
        errors => [{details => 'big problem', fail => 1}],
    };
    my $out = $comp->render_brief($f);
    is($out, [['error', 'FATAL', 'big problem']], 'errors shown in brief');
};

# ===========================================================================
# Harness facet renderers
# ===========================================================================

subtest 'render_launch' => sub {
    my $f   = {harness_job_launch => {stamp => '1234567890.123'}};
    my $out = $comp->render_launch($f);
    is($out, ['harness', 'HARNESS', 'Job Launched at 1234567890.123'], 'launch renders stamp');
};

subtest 'render_start' => sub {
    my $f   = {harness_job_start => {details => 'Starting t/foo.t'}};
    my $out = $comp->render_start($f);
    is($out, ['harness', 'HARNESS', 'Starting t/foo.t'], 'start renders details');
};

subtest 'render_exit' => sub {
    my $f   = {harness_job_exit => {details => 'Test exited with 0'}};
    my $out = $comp->render_exit($f);
    is($out, ['harness', 'HARNESS', 'Test exited with 0'], 'exit renders details');
};

subtest 'render_end' => sub {
    my $f   = {harness_job_end => {stamp => '1234567890.456'}};
    my $out = $comp->render_end($f);
    is($out, ['harness', 'HARNESS', 'Job completed at 1234567890.456'], 'end renders stamp');
};

# ===========================================================================
# render_super_verbose
# ===========================================================================

subtest 'render_super_verbose - includes harness facets' => sub {
    my $f = {
        harness_job_launch => {stamp   => '100'},
        harness_job_start  => {details => 'starting'},
    };
    my $out = $comp->render_super_verbose($f);
    ok(@$out >= 2, 'at least launch + start');
    is($out->[0], ['harness', 'HARNESS', 'Job Launched at 100'], 'launch');
    is($out->[1], ['harness', 'HARNESS', 'starting'],            'start');
};

subtest 'render_super_verbose - fallback for unknown facets' => sub {
    my $f = {
        harness_custom_thing => {details => 'custom details'},
    };
    my $out = $comp->render_super_verbose($f);
    is(scalar @$out, 1,                                        'one fallback line');
    is($out->[0],    ['harness', 'HARNESS', 'custom details'], 'uses details from harness facet');
};

subtest 'render_super_verbose - control with encoding in super_verbose' => sub {
    my $f = {
        control => {encoding => 'utf8'},
    };
    my $out = $comp->render_super_verbose($f);
    ok(@$out >= 1, 'at least one component');
    is($out->[0], ['control', 'ENCODING', 'utf8'], 'encoding shown in super_verbose');
};

# ===========================================================================
# Individual renderers
# ===========================================================================

subtest 'render_plan - skip all with reason' => sub {
    my $f   = {plan => {skip => 1, details => 'Not on this OS'}};
    my $out = $comp->render_plan($f);
    is($out, ['plan', 'SKIP ALL', 'Not on this OS'], 'skip all with reason');
};

subtest 'render_plan - skip all without reason' => sub {
    my $f   = {plan => {skip => 1}};
    my $out = $comp->render_plan($f);
    is($out, ['plan', 'SKIP ALL', 'No reason given'], 'skip all no reason');
};

subtest 'render_plan - no plan' => sub {
    my $f   = {plan => {none => 1, details => 'NO PLAN'}};
    my $out = $comp->render_plan($f);
    is($out, ['plan', 'NO  PLAN', 'NO PLAN'], 'no plan');
};

subtest 'render_assert - unnamed' => sub {
    my $f   = {assert => {pass => 0}};
    my $out = $comp->render_assert($f);
    is($out, ['assert', 'FAIL', '<UNNAMED ASSERTION>'], 'unnamed assertion');
};

subtest 'render_amnesty - deduplication' => sub {
    my $f = {
        amnesty => [
            {tag => 'TODO', details => 'wip'},
            {tag => 'TODO', details => 'wip'},
            {tag => 'SKIP', details => 'skipping'},
        ],
    };
    my @out = $comp->render_amnesty($f);
    is(scalar @out, 2, 'duplicate amnesty deduplicated');
    is($out[0],     ['amnesty', 'TODO', 'wip'],      'first amnesty');
    is($out[1],     ['amnesty', 'SKIP', 'skipping'], 'second amnesty');
};

subtest 'render_debug - with trace frame' => sub {
    my $f = {
        assert => {details => 'test'},
        trace  => {frame   => ['Foo', 'foo.t', 42, 'Foo::bar']},
    };
    my $out = $comp->render_debug($f);
    is($out, ['trace', 'DEBUG', 'foo.t line 42'], 'debug from frame');
};

subtest 'render_debug - with trace details' => sub {
    my $f = {
        assert => {details => 'test'},
        trace  => {details => 'at bar.t line 7'},
    };
    my $out = $comp->render_debug($f);
    is($out, ['trace', 'DEBUG', 'at bar.t line 7'], 'debug from trace details');
};

subtest 'render_debug - no trace' => sub {
    my $f = {
        assert => {details => 'test'},
    };
    my $out = $comp->render_debug($f);
    is($out, ['trace', 'DEBUG', '[No trace info available]'], 'debug without trace');
};

subtest 'render_info - reference details uses Data::Dumper' => sub {
    my $f = {
        info => [{tag => 'DIAG', details => {foo => 'bar'}}],
    };
    my @out = $comp->render_info($f);
    is(scalar @out,      1,      'one info line');
    is($out[0]->[0],     'info', 'facet is info');
    is($out[0]->[1],     'DIAG', 'tag is DIAG');
    is(ref $out[0]->[2], 'HASH', 'details preserved as reference');
};

subtest 'render_info - with table' => sub {
    my $table = {header => ['col1'], rows => [['val1']]};
    my $f     = {
        info => [{tag => 'NOTE', details => 'table info', table => $table}],
    };
    my @out = $comp->render_info($f);
    is(scalar @out,  1,      'one info line');
    is($out[0]->[3], $table, 'table passed through as 4th element');
};

subtest 'render_errors - fatal vs error tag' => sub {
    my $f = {
        errors => [
            {details => 'fatal error',     fail => 1},
            {details => 'non-fatal error', fail => 0},
            {details => 'tagged error',    tag  => 'CUSTOM'},
        ],
    };
    my @out = $comp->render_errors($f);
    is(scalar @out, 3, 'three error lines');
    is($out[0],     ['error', 'FATAL',  'fatal error'],     'fail => 1 gets FATAL');
    is($out[1],     ['error', 'ERROR',  'non-fatal error'], 'fail => 0 gets ERROR');
    is($out[2],     ['error', 'CUSTOM', 'tagged error'],    'explicit tag used');
};

subtest 'render_about - no_display suppresses output' => sub {
    my $f   = {about => {no_display => 1, details => 'hidden'}};
    my $out = $comp->render_about($f);
    ok(!defined $out, 'no_display suppresses about');
};

subtest 'render_about - no details suppresses output' => sub {
    my $f   = {about => {package => 'Foo::Bar'}};
    my $out = $comp->render_about($f);
    ok(!defined $out, 'no details suppresses about');
};

subtest 'render_control - non-halt in normal mode returns nothing' => sub {
    my $f   = {control => {details => 'some control'}};
    my @out = $comp->render_control($f);
    is(scalar @out, 0, 'non-halt control returns nothing in normal mode');
};

subtest 'render_control - non-halt in super_verbose mode' => sub {
    my $f   = {control => {details => 'some control'}};
    my @out = $comp->render_control($f, super_verbose => 1);
    is(scalar @out, 1,                                      'non-halt control returns line in super_verbose');
    is($out[0],     ['control', 'CONTROL', 'some control'], 'control details shown');
};

done_testing;
