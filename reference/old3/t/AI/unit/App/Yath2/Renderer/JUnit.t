use Test2::V0;

use App::Yath2::Renderer::JUnit;

my $CLASS = 'App::Yath2::Renderer::JUnit';

sub ev {
    my (%fd) = @_;
    return {event_id => 'test-id', stamp => 1000, facet_data => \%fd};
}

subtest 'desired_filters returns Verbose' => sub {
    my $r = $CLASS->new;
    my @f = $r->desired_filters;
    is(scalar @f, 1, 'one filter');
    is($f[0], 'App::Yath2::Filter::Verbose', 'Verbose filter');
};

subtest 'render_event skips events with no job_id' => sub {
    my $r = $CLASS->new;
    ok(lives { $r->render_event(ev(assert => {pass => 1, details => 'ok'})) }, 'no die with no job_id');
    is(scalar keys %{$r->{'tests'}}, 0, 'no test entries');
};

subtest 'render_event harness_job_start creates test entry' => sub {
    my $r = $CLASS->new;
    my $event = {
        event_id   => 'e1',
        stamp      => 1000,
        facet_data => {
            harness_job_start => {
                job_id   => 'job-abc',
                abs_file => '/path/to/t/foo.t',
                rel_file => 't/foo.t',
                job_try  => 0,
            },
        },
    };
    ok(lives { $r->render_event($event) }, 'no die on job_start');
    ok(exists $r->{'tests'}{'job-abc'}, 'test entry created');
    is($r->{'tests'}{'job-abc'}{'job_id'}, 'job-abc', 'job_id stored');
    is($r->{'tests'}{'job-abc'}{'file'}, 't/foo.t', 'file stored');
    is($r->{'tests'}{'job-abc'}{'start'}, 1000, 'start stamp stored');
};

subtest 'render_event assert accumulates into test' => sub {
    my $r = $CLASS->new;

    $r->render_event({
        event_id   => 'e1',
        stamp      => 1000,
        facet_data => {
            harness_job_start => {
                job_id   => 'job-xyz',
                abs_file => '/path/to/t/bar.t',
                rel_file => 't/bar.t',
            },
        },
    });

    my $assert_event = {
        event_id   => 'e2',
        stamp      => 1001,
        facet_data => {
            harness => {job_id => 'job-xyz'},
            assert  => {pass => 1, details => 'basic test', number => 1},
        },
    };
    ok(lives { $r->render_event($assert_event) }, 'no die on assert');
    is($r->{'tests'}{'job-xyz'}{'testsuite'}{'tests'}, 1, 'test count incremented');
};

subtest 'render_event harness_job_end finalizes test entry' => sub {
    my $r = $CLASS->new;

    $r->render_event({
        event_id   => 'e1',
        stamp      => 1000,
        facet_data => {
            harness_job_start => {
                job_id   => 'job-fin',
                abs_file => '/path/to/t/baz.t',
                rel_file => 't/baz.t',
            },
        },
    });

    my $end_event = {
        event_id   => 'e3',
        stamp      => 1005,
        facet_data => {
            harness_job_end => {
                job_id   => 'job-fin',
                rel_file => 't/baz.t',
                fail     => 0,
            },
        },
    };
    ok(lives { $r->render_event($end_event) }, 'no die on job_end');
    ok(defined $r->{'tests'}{'job-fin'}{'stop'}, 'stop time recorded');
    is($r->{'tests'}{'job-fin'}{'stop'}, 1005, 'correct stop time');
};

done_testing;
