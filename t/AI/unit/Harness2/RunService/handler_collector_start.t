use Test2::V0;
use File::Temp qw/tempdir/;

use lib 't/lib';
use Test2::Harness2::RunService;
use Test2::Harness2::Run;

# Verify _handle_gen_msg_collector_start / _handle_gen_msg_collector_end
# convert the IPC content into a synthetic event with a
# harness_collector_start / harness_collector_end facet on the run
# service's local emitter (which the run-service's own collector
# pipeline writes to runs/<id>/events.jsonl.zst).

{
    package Test::RunSvc::FakeMsg;
    sub new     { my ($c, $body) = @_; bless {body => $body}, $c }
    sub content { $_[0]->{body} }
}

subtest 'collector_start IPC -> harness_collector_start event via emitter' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $run = Test2::Harness2::Run->new(run_id => 'r-coll');
    my $svc = Test2::Harness2::RunService->new(workdir => $dir, run => $run);

    # Capture every raw event the service emits via the local emitter.
    my @emitted;
    no warnings 'redefine';
    local *Test2::Harness2::Util::EventEmitter::emit_raw = sub {
        my ($self, $event) = @_;
        push @emitted, $event;
        return 'fake-sync';
    };

    # Install a stub emitter so _handle_gen_msg_collector_start has
    # something to call emit_raw on. We use a plain blessed hash so
    # we don't have to wire up Atomic::Pipe in unit tests.
    $svc->{Test2::Harness2::RunService::EMITTER()}
        = bless {}, 'Test2::Harness2::Util::EventEmitter';

    my $payload = {
        kind          => 'collector_start',
        type          => 'Job',
        id            => 7,
        run_id        => 'r-coll',
        job_id        => 7,
        job_try       => 0,
        service_name  => undef,
        collector_pid => 11111,
        collected_pid => 22222,
        started_at    => 1714875000.123,
        spec          => {file => '/tmp/x.t', collector_pid => 11111},
    };

    $svc->run_on_general_message(Test::RunSvc::FakeMsg->new($payload));

    is(scalar @emitted, 1, 'one event emitted via emitter');

    my $fd = $emitted[0]{facet_data};
    ok(ref($fd) eq 'HASH', 'event has facet_data');
    ok(exists $fd->{harness_collector_start}, 'has top-level harness_collector_start facet');

    my $facet = $fd->{harness_collector_start};
    ok(ref($facet) eq 'HASH', 'facet is hashref');
    is($facet->{kind},          'collector_start', 'kind preserved');
    is($facet->{type},          'Job',             'type preserved');
    is($facet->{id},            7,                 'id preserved');
    is($facet->{run_id},        'r-coll',          'run_id preserved');
    is($facet->{job_id},        7,                 'job_id preserved');
    is($facet->{job_try},       0,                 'job_try preserved');
    is($facet->{collector_pid}, 11111,             'collector_pid preserved');
    is($facet->{collected_pid}, 22222,             'collected_pid preserved');
    is($facet->{started_at},    1714875000.123,    'started_at preserved');
    is($facet->{spec}{file},    '/tmp/x.t',        'spec hash preserved');
};

subtest 'collector_end IPC -> harness_collector_end event via emitter' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $run = Test2::Harness2::Run->new(run_id => 'r-coll-end');
    my $svc = Test2::Harness2::RunService->new(workdir => $dir, run => $run);

    my @emitted;
    no warnings 'redefine';
    local *Test2::Harness2::Util::EventEmitter::emit_raw = sub {
        my ($self, $event) = @_;
        push @emitted, $event;
        return 'fake-sync';
    };

    $svc->{Test2::Harness2::RunService::EMITTER()}
        = bless {}, 'Test2::Harness2::Util::EventEmitter';

    my $payload = {
        kind          => 'collector_end',
        type          => 'Job',
        id            => 7,
        run_id        => 'r-coll-end',
        job_id        => 7,
        job_try       => 0,
        collector_pid => 11111,
        collected_pid => 22222,
        exit          => 0,
        exit_decoded  => {err => 0, sig => 0},
        ended_at      => 1714875042.987,
        state         => {pass => 1, fail_count => 0, ended_at => 1714875042.987},
    };

    $svc->run_on_general_message(Test::RunSvc::FakeMsg->new($payload));

    is(scalar @emitted, 1, 'one event emitted');

    my $fd = $emitted[0]{facet_data};
    ok(ref($fd) eq 'HASH', 'event has facet_data');
    my $facet = $fd->{harness_collector_end};
    ok(ref($facet) eq 'HASH', 'has top-level harness_collector_end facet');
    is($facet->{kind}, 'collector_end',   'kind preserved');
    is($facet->{type}, 'Job',             'type preserved');
    is($facet->{exit}, 0,                 'exit preserved');
    is($facet->{exit_decoded},     $payload->{exit_decoded}, 'exit_decoded preserved');
    is($facet->{ended_at},         1714875042.987,           'ended_at preserved');
    is($facet->{state}{pass},      1,                        'state.pass preserved');
};

subtest 'no emitter -> handler is a no-op' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $run = Test2::Harness2::Run->new(run_id => 'r-noemit');
    my $svc = Test2::Harness2::RunService->new(workdir => $dir, run => $run);

    # No emitter installed; should not blow up.
    my $ok = eval {
        $svc->run_on_general_message(Test::RunSvc::FakeMsg->new({
            kind => 'collector_start',
            type => 'Job', id => 1, run_id => 'r-noemit',
        }));
        1;
    };
    ok($ok, 'no-op when emitter missing');
};

done_testing;
