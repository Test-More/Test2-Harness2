use Test2::V0;
use Test2::Harness2::Event;
use Test2::Harness2::Collector::Observer::TestObserver;

# Fake collector that collects every send_ipc call for inspection.
{

    package T2H2_TestObsFakeCollector;
    use Object::HashBase qw{
        <ipc_run
        <ipc_harness
        <bus_id
        <child_pid
        <auditor
        +sends
    };
    sub init { $_[0]->{sends} //= [] }

    sub send_ipc {
        my ($self, $target, $content) = @_;
        push @{$self->{sends}} => [$target, {%$content}];
    }
}

# Minimal auditor with pass / counts so _emit_completed can stamp them.
{

    package T2H2_TestObsFakeAuditor;
    sub new        { my ($c, %a) = @_; bless {%a}, $c }
    sub pass       { $_[0]->{pass} ? 1 : 0 }
    sub pass_count { $_[0]->{pass_count} // 0 }
    sub fail_count { $_[0]->{fail_count} // 0 }
}

sub make_event {
    my %fd = @_;
    return Test2::Harness2::Event->new(
        event_id   => 'E-' . int(rand 1e6),
        stamp      => 0,
        facet_data => \%fd,
    );
}

sub new_observer {
    my %override = @_;

    my $obs = Test2::Harness2::Collector::Observer::TestObserver->new(
        run_id    => 'R',
        job_id    => 'J',
        job_try   => 0,
        ipcm_info => {},
    );

    my $collector = T2H2_TestObsFakeCollector->new(
        ipc_run     => $override{ipc_run}     // 'run-R',
        ipc_harness => $override{ipc_harness} // 'harness',
        bus_id      => 'collector:J:R',
        child_pid   => 99999,
        auditor     => $override{auditor},
    );

    $obs->startup($collector);
    return ($obs, $collector);
}

subtest 'startup fires test_job_started to ipc_run' => sub {
    my ($obs, $coll) = new_observer();

    is(scalar @{$coll->{sends}}, 1, 'one message sent at startup');
    my ($target, $msg) = @{$coll->{sends}[0]};
    is($target,               'run-R',            'targeted the run service');
    is($msg->{kind},          'test_job_started', 'kind is test_job_started');
    is($msg->{run_id},        'R',                'run_id');
    is($msg->{job_id},        'J',                'job_id');
    is($msg->{test_pid},      99999,              'test pid');
    is($msg->{collector_pid}, $$,                 'collector pid');
};

subtest 'first failing assertion fires test_job_failing exactly once' => sub {
    my ($obs, $coll) = new_observer();

    $obs->observe_event(make_event(assert => {pass => 1}));
    is(scalar @{$coll->{sends}}, 1, 'passing assert does not fire failing');

    $obs->observe_event(make_event(assert => {pass => 0}));
    is(scalar @{$coll->{sends}},    2,                  'failing assert fired one message');
    is($coll->{sends}[-1][1]{kind}, 'test_job_failing', 'fired test_job_failing');

    $obs->observe_event(make_event(assert => {pass => 0}));
    is(scalar @{$coll->{sends}}, 2, 'second failing assert does not re-fire');
};

subtest 'stderr output fires test_job_diagnosing exactly once' => sub {
    my ($obs, $coll) = new_observer();

    $obs->observe_event(make_event(from_stream => {source => 'STDERR'}));
    my @kinds = map { $_->[1]{kind} } @{$coll->{sends}};
    is(
        [grep { $_ eq 'test_job_diagnosing' } @kinds],
        ['test_job_diagnosing'],
        'fired test_job_diagnosing',
    );

    $obs->observe_event(make_event(from_stream => {source => 'STDERR'}));
    @kinds = map { $_->[1]{kind} } @{$coll->{sends}};
    is(
        [grep { $_ eq 'test_job_diagnosing' } @kinds],
        ['test_job_diagnosing'],
        'second STDERR does not re-fire',
    );
};

subtest 'harness_job_exit facet fires test_job_completed + job_release' => sub {
    my $audit = T2H2_TestObsFakeAuditor->new(pass => 1, pass_count => 3, fail_count => 0);
    my ($obs, $coll) = new_observer(auditor => $audit);

    $obs->observe_event(make_event(
        harness_job_exit => {
            exit  => 0,
            codes => {err => 0, sig => 0, dmp => 0, all => 0},
        },
    ));

    my @kinds_and_targets = map { [$_->[0], $_->[1]{kind}] } @{$coll->{sends}};
    # startup fired one test_job_started + two completion messages.
    is(scalar @kinds_and_targets, 3, 'three messages total');
    is($kinds_and_targets[0],     ['run-R',   'test_job_started']);
    is($kinds_and_targets[1],     ['run-R',   'test_job_completed']);
    is($kinds_and_targets[2],     ['harness', 'job_release']);

    my $completed = $coll->{sends}[1][1];
    is($completed->{exit},       0, 'exit carried');
    is($completed->{pass},       1, 'pass from auditor');
    is($completed->{pass_count}, 3, 'pass_count from auditor');
    is($completed->{fail_count}, 0, 'fail_count from auditor');

    my $release = $coll->{sends}[2][1];
    is($release->{run_id}, 'R', 'job_release carries run_id');
    is($release->{job_id}, 'J', 'job_release carries job_id');
    ok(!exists $release->{exit}, 'job_release is outcome-agnostic (no exit)');
};

subtest 'harness_job_exit is idempotent: second one does not re-fire' => sub {
    my ($obs, $coll) = new_observer();

    $obs->observe_event(make_event(harness_job_exit => {exit => 0, codes => {}}));
    my $n = scalar @{$coll->{sends}};

    $obs->observe_event(make_event(harness_job_exit => {exit => 0, codes => {}}));
    is(scalar @{$coll->{sends}}, $n, 'no extra messages on second harness_job_exit');
};

done_testing;
