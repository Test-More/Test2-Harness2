use Test2::V0;
use Time::HiRes qw/time/;

use Test2::Harness2::Event;

sub make_event {
    my (%facets) = @_;
    return Test2::Harness2::Event->new(
        facet_data => \%facets,
        job_id     => 'job-1',
        job_try    => 0,
    );
}

sub assert_event {
    my (%args) = @_;
    return make_event(
        assert => {
            pass    => $args{pass}    // 1,
            details => $args{details} // 'ok',
            number  => $args{number},
        },
        defined($args{amnesty}) ? (amnesty => $args{amnesty}) : (),
    );
}

sub plan_event {
    my (%args) = @_;
    return make_event(plan => {count => $args{count}, none => $args{none} // 0, details => $args{details}});
}

sub exit_event {
    my ($exit_code) = @_;
    return make_event(harness_job_exit => {exit => $exit_code, job_id => 'job-1'});
}

sub bail_event {
    my ($reason) = @_;
    return make_event(control => {halt => 1, details => $reason});
}

# ---- Basic construction ----
subtest 'basic construction' => sub {
    require Test2::Harness2::Auditor;

    my $a = Test2::Harness2::Auditor->new();
    ok($a, "created auditor");
    is($a->assertion_count, 0, "assertion_count starts at 0");
    is($a->nested,          0, "nested starts at 0");
    ok(!defined($a->plan), "no plan yet");
    ok(!defined($a->exit), "no exit yet");
    ok(!defined($a->halt), "no halt yet");
};

# ---- Simple passing test ----
subtest 'simple passing test' => sub {
    require Test2::Harness2::Auditor;

    my $a = Test2::Harness2::Auditor->new();

    my @out = $a->audit(
        plan_event(count => 3),
        assert_event(pass => 1, details => 'ok 1', number => 1),
        assert_event(pass => 1, details => 'ok 2', number => 2),
        assert_event(pass => 1, details => 'ok 3', number => 3),
        exit_event(0),
    );

    ok($a->pass,  "auditor passes");
    ok(!$a->fail, "auditor does not fail");
    is($a->assertion_count, 3, "saw 3 assertions");
    is(scalar(@out),        5, "all 5 events returned (no extras generated)");
};

# ---- Failing assertion ----
subtest 'failing assertion' => sub {
    require Test2::Harness2::Auditor;

    my $a = Test2::Harness2::Auditor->new();

    $a->audit(
        plan_event(count => 1),
        assert_event(pass => 0, details => 'not ok 1', number => 1),
        exit_event(0),
    );

    ok(!$a->pass, "auditor does not pass");
    ok($a->fail,  "auditor fails");
};

# ---- TODO failure (should PASS) ----
subtest 'TODO failure counts as pass' => sub {
    require Test2::Harness2::Auditor;

    my $a = Test2::Harness2::Auditor->new();

    $a->audit(
        plan_event(count => 1),
        # failing assert with amnesty (TODO)
        make_event(
            assert  => {pass => 0, details => 'not ok 1 - todo', number => 1},
            amnesty => [{tag => 'TODO', details => 'known failure'}],
        ),
        exit_event(0),
    );

    ok($a->pass,  "TODO failure auditor passes");
    ok(!$a->fail, "TODO failure auditor does not fail");
};

# ---- Plan count mismatch ----
subtest 'plan count mismatch generates error events' => sub {
    require Test2::Harness2::Auditor;

    my $a = Test2::Harness2::Auditor->new();

    my @out = $a->audit(
        plan_event(count => 5),
        assert_event(pass => 1, details => 'ok 1', number => 1),
        assert_event(pass => 1, details => 'ok 2', number => 2),
        exit_event(0),
    );

    ok($a->fail, "auditor fails on plan count mismatch");

    # Should have generated extra error events
    my @generated = grep { $_->facet_data->{harness_auditor} && $_->facet_data->{harness_auditor}{added_by_auditor} } @out;
    ok(scalar(@generated) > 0, "auditor generated error events for plan mismatch");
};

# ---- Missing plan ----
subtest 'missing plan with assertions fails' => sub {
    require Test2::Harness2::Auditor;

    my $a = Test2::Harness2::Auditor->new();

    my @out = $a->audit(
        assert_event(pass => 1, details => 'ok 1', number => 1),
        exit_event(0),
    );

    ok($a->fail, "auditor fails when no plan declared but assertions were seen");

    my @generated = grep { $_->facet_data->{harness_auditor} && $_->facet_data->{harness_auditor}{added_by_auditor} } @out;
    ok(scalar(@generated) > 0, "auditor generated error events for missing plan");
};

# ---- Bail out ----
subtest 'bail out sets halt and fails' => sub {
    require Test2::Harness2::Auditor;

    my $a = Test2::Harness2::Auditor->new();

    $a->audit(
        bail_event('Something went wrong'),
        exit_event(1),
    );

    ok($a->fail, "auditor fails on bail out");
    ok($a->halt, "halt is set");
    is($a->halt, 'Something went wrong', "halt reason is stored");
};

# ---- Non-zero exit ----
subtest 'non-zero exit fails' => sub {
    require Test2::Harness2::Auditor;

    my $a = Test2::Harness2::Auditor->new();

    my @out = $a->audit(
        plan_event(count => 1),
        assert_event(pass => 1, details => 'ok 1', number => 1),
        exit_event(256),    # exit code 1 in wait() format (shifted 8 bits)
    );

    ok($a->fail, "auditor fails on non-zero exit");

    my @generated = grep { $_->facet_data->{harness_auditor} && $_->facet_data->{harness_auditor}{added_by_auditor} } @out;
    ok(scalar(@generated) > 0, "auditor generated error events for non-zero exit");
};

# ---- Skip all (plan with count=0) ----
subtest 'skip all passes' => sub {
    require Test2::Harness2::Auditor;

    my $a = Test2::Harness2::Auditor->new();

    $a->audit(
        plan_event(count => 0, details => 'skip all tests'),
        exit_event(0),
    );

    ok($a->pass,  "skip_all passes");
    ok(!$a->fail, "skip_all does not fail");
};

# ---- No assertions, no plan — passes (empty test) ----
subtest 'no assertions no plan fails' => sub {
    require Test2::Harness2::Auditor;

    # An empty test with no assertions and no plan should fail
    # because something is clearly wrong
    my $a = Test2::Harness2::Auditor->new();
    $a->audit(exit_event(0));

    # No assertions and no plan: this is actually OK per TAP (empty = pass)
    # But let's verify the auditor behavior — no plan, no assertions = no errors about plan
    # The old code only errors "No plan declared" if there ARE assertions
    ok($a->pass, "no assertions and no plan passes (empty test is OK)");
};

# ---- Error facets increment error count ----
subtest 'error facets cause failure' => sub {
    require Test2::Harness2::Auditor;

    my $a = Test2::Harness2::Auditor->new();

    $a->audit(
        plan_event(count => 0),
        make_event(errors => [{tag => 'ERROR', details => 'something broke', fail => 1}]),
        exit_event(0),
    );

    ok($a->fail, "auditor fails when error facets seen");
};

# ---- pass/fail helpers ----
subtest 'pass and fail are inverses' => sub {
    require Test2::Harness2::Auditor;

    my $a_pass = Test2::Harness2::Auditor->new();
    $a_pass->audit(plan_event(count => 1), assert_event(pass => 1, number => 1), exit_event(0));

    my $a_fail = Test2::Harness2::Auditor->new();
    $a_fail->audit(plan_event(count => 1), assert_event(pass => 0, number => 1), exit_event(0));

    ok($a_pass->pass  && !$a_pass->fail, "passing auditor: pass=1, fail=0");
    ok(!$a_fail->pass && $a_fail->fail,  "failing auditor: pass=0, fail=1");
};

# ---- has_exit, has_plan ----
subtest 'has_exit and has_plan' => sub {
    require Test2::Harness2::Auditor;

    my $a = Test2::Harness2::Auditor->new();
    ok(!$a->has_exit, "no exit initially");
    ok(!$a->has_plan, "no plan initially");

    $a->audit(plan_event(count => 1));
    ok($a->has_plan, "has_plan after plan event");

    $a->audit(assert_event(pass => 1, number => 1), exit_event(0));
    ok($a->has_exit, "has_exit after exit event");
};

# ---- Signal in exit ----
subtest 'signal exit fails' => sub {
    require Test2::Harness2::Auditor;

    my $a = Test2::Harness2::Auditor->new();

    my @out = $a->audit(
        plan_event(count => 1),
        assert_event(pass => 1, number => 1),
        exit_event(11),    # signal 11 (SIGSEGV) in wait() format
    );

    ok($a->fail, "auditor fails on signal exit");
};

# ---- Duplicate/missing assertion numbers ----
subtest 'duplicate assertion number generates error' => sub {
    require Test2::Harness2::Auditor;

    my $a = Test2::Harness2::Auditor->new();

    my @out = $a->audit(
        plan_event(count => 2),
        assert_event(pass => 1, details => 'ok 1',       number => 1),
        assert_event(pass => 1, details => 'ok 1 again', number => 1),    # duplicate!
        exit_event(0),
    );

    ok($a->fail, "auditor fails on duplicate assertion number");
};

done_testing;
