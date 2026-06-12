use Test2::V0;
use Test2::Harness2::Event;
use Test2::Harness2::Collector::Auditor::Test;

sub _mk_event {
    my (%facets) = @_;
    return Test2::Harness2::Event->new(facet_data => {%facets});
}

subtest passing_run => sub {
    my $a = Test2::Harness2::Collector::Auditor::Test->new;
    $a->startup;
    $a->audit_event(_mk_event(assert => {pass => 1, number => 1, details => 'one'}));
    $a->audit_event(_mk_event(assert => {pass => 1, number => 2, details => 'two'}));
    $a->audit_event(_mk_event(plan   => {count => 2}));
    $a->audit_event(_mk_event(harness_process_exit => {all => 0}));
    $a->shutdown;

    ok($a->pass,              'passes');
    is($a->fail_count, 0,     'no failures');
    is($a->pass_count, 2,     'two passes');
    is($a->assertion_count, 2);
    ok($a->has_exit,          'has exit');
    ok($a->has_plan,          'has plan');
};

subtest failing_assertion => sub {
    my $a = Test2::Harness2::Collector::Auditor::Test->new;
    $a->startup;
    $a->audit_event(_mk_event(assert => {pass => 0, number => 1, details => 'bad'}));
    $a->audit_event(_mk_event(plan   => {count => 1}));
    $a->audit_event(_mk_event(harness_process_exit => {all => 0}));

    ok($a->fail,             'fails');
    ok(!$a->pass,            'not passing');
    is($a->fail_count >= 1, T());
};

subtest bail_out => sub {
    my $a = Test2::Harness2::Collector::Auditor::Test->new;
    $a->startup;
    $a->audit_event(_mk_event(control => {halt => 1, details => 'flood'}));
    is($a->halt, 'flood', 'halt reason captured');
    ok($a->fail, 'fails after halt');
};

subtest state_transitions_via_recorder => sub {
    my @calls;
    my $rec = Test_Recorder->new(\@calls);

    my $a = Test2::Harness2::Collector::Auditor::Test->new(recorder => $rec);
    $a->startup;
    $a->audit_event(_mk_event(assert => {pass => 0, number => 1, details => 'bad'}));
    $a->audit_event(_mk_event(plan   => {count => 1}));
    $a->shutdown;

    is(
        [map { $_->[0] } @calls],
        ['starting', 'failing', 'completed'],
        'recorder saw starting -> failing -> completed',
    );
};

subtest diagnostic_event_transitions => sub {
    my @calls;
    my $rec = Test_Recorder->new(\@calls);

    my $a = Test2::Harness2::Collector::Auditor::Test->new(recorder => $rec);
    $a->startup;
    $a->audit_event(_mk_event(info => [{important => 1, details => 'hmm'}]));
    $a->shutdown;

    my @states = map { $_->[0] } @calls;
    is(\@states, ['starting', 'diagnosing', 'completed'], 'starting -> diagnosing -> completed');
};

subtest missing_plan_marks_failure => sub {
    my $a = Test2::Harness2::Collector::Auditor::Test->new;
    $a->audit_event(_mk_event(assert => {pass => 1, number => 1, details => 'a'}));
    $a->audit_event(_mk_event(harness_process_exit => {all => 0}));

    ok($a->fail, 'no-plan condition fails');
    my @errs = $a->fail_error_facet_list;
    ok((grep { $_->{details} =~ /plan/i } @errs), 'fail list mentions plan');
};

done_testing;

package Test_Recorder;
sub new {
    my ($class, $log) = @_;
    return bless {log => $log}, $class;
}
sub record_event    { 1 }
sub record_state    { push @{$_[0]->{log}} => [$_[1], $_[2]] }
sub record_exit     { 1 }
sub record_artifact { 1 }
sub finalize        { 1 }
