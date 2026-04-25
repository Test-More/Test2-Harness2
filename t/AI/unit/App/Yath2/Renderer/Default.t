use Test2::V0;
use Test2::Plugin::NoWarnings;

use App::Yath2::Renderer::Default;
use App::Yath2::OutputManager;

my $CLASS = 'App::Yath2::Renderer::Default';

sub make_renderer {
    my (%opts) = @_;
    my $buf = '';
    open(my $fh, '>', \$buf) or die "open scalar: $!";
    my $r = $CLASS->new(io => $fh, color => 0, tty => 0, %opts);
    return ($r, \$buf);
}

sub ev {
    my (%fd) = @_;
    return {event_id => 'test-id', stamp => 1, facet_data => \%fd};
}

subtest 'compiles and constructs' => sub {
    my ($r) = make_renderer();
    ok($r, 'renderer constructed');
    isa_ok($r, [$CLASS], 'correct class');
};

subtest 'desired_filters default returns Verbose filter' => sub {
    my ($r) = make_renderer();
    my @f = $r->desired_filters;
    is(scalar @f, 1, 'one filter');
    is($f[0], 'App::Yath2::Filter::Verbose', 'Verbose filter');
};

subtest 'desired_filters quiet returns Quiet filter' => sub {
    my ($r) = make_renderer(settings => {log_level => 'quiet'});
    my @f = $r->desired_filters;
    is(scalar @f, 1, 'one filter');
    is($f[0], 'App::Yath2::Filter::Quiet', 'Quiet filter');
};

subtest 'desired_filters verbose returns Verbose filter' => sub {
    my ($r) = make_renderer(settings => {log_level => 'verbose'});
    my @f = $r->desired_filters;
    is(scalar @f, 1, 'one filter');
    is($f[0], 'App::Yath2::Filter::Verbose', 'Verbose filter');
};

subtest 'render_event writes assert output' => sub {
    my ($r, $buf) = make_renderer();
    $r->render_event(ev(assert => {pass => 1, details => 'basic check'}));
    like($$buf, qr/PASS/, 'pass tag written');
    like($$buf, qr/basic check/, 'assert details written');
};

subtest 'render_event writes FAIL for failing assert' => sub {
    my ($r, $buf) = make_renderer();
    $r->render_event(ev(assert => {pass => 0, details => 'bad thing'}));
    like($$buf, qr/FAIL/, 'fail tag written');
    like($$buf, qr/bad thing/, 'assert details written');
};

subtest 'render_event writes PASSED line for harness_job_end pass' => sub {
    my ($r, $buf) = make_renderer();
    $r->render_event(ev(harness_job_end => {job_id => 'job-99', fail => 0}));
    like($$buf, qr/PASSED/, 'PASSED tag written');
    like($$buf, qr/job-99/, 'job_id written');
};

subtest 'render_event writes FAILED line for harness_job_end fail' => sub {
    my ($r, $buf) = make_renderer();
    $r->render_event(ev(harness_job_end => {job_id => 'job-42', fail => 1}));
    like($$buf, qr/FAILED/, 'FAILED tag written');
    like($$buf, qr/job-42/, 'job_id written');
};

subtest 'render_event writes plan output' => sub {
    my ($r, $buf) = make_renderer();
    $r->render_event(ev(plan => {count => 3}));
    like($$buf, qr/PLAN/, 'plan tag written');
    like($$buf, qr/3/, 'plan count written');
};

subtest 'write() emits no warnings for nested event with undef job_id in verbose mode' => sub {
    # Regression: push @{$self->{+_BUFFER}->{$job_id}} warned when $job_id was
    # undef for harness-level events that carry a hub with nested > 0 but no
    # job_id facet (e.g. runner-internal subtests).
    my ($r, $buf) = make_renderer();    # VERBOSE defaults to 1
    $r->render_event(ev(
        hubs   => [{nested => 1}],
        assert => {pass => 1, details => 'nested event without job_id'},
    ));
    ok(1, 'no warnings from write() for nested event with undef job_id');
};

subtest 'finish does not die' => sub {
    my ($r) = make_renderer();
    ok(lives { $r->finish }, 'finish does not die');
};

subtest 'integrates with OutputManager' => sub {
    my $buf = '';
    open(my $fh, '>', \$buf) or die "open scalar: $!";
    my $r = $CLASS->new(io => $fh, color => 0, tty => 0);
    my $om  = App::Yath2::OutputManager->new;
    $om->add_renderer($r);
    $om->dispatch(ev(assert => {pass => 1, details => 'om check'}));
    $om->finish;
    like($buf, qr/PASS/, 'event reached renderer via OutputManager');
    like($buf, qr/om check/, 'details present');
};

done_testing;
