use Test2::V0;
use File::Temp qw/tempdir/;

use lib 't/lib';
use Test2::Harness2;

# The harness service receives collector_start / collector_end IPC
# from run-service collectors and global-service collectors. Each
# kind reflects into the harness's own outgoing event stream as a
# harness_collector_start / harness_collector_end facet, so the
# harness's own collector pipeline writes the row to
# services/harness/events.jsonl.zst. That row is the on-disk entry
# point a Log iterator follows to descend into the run/global-service
# events.jsonl.zst.

{
    package Test::Harness2::FakeMsg;
    sub new     { my ($c, $body) = @_; bless {body => $body}, $c }
    sub content { $_[0]->{body} }
}

sub mk_harness {
    my $dir = tempdir(CLEANUP => 1);
    return Test2::Harness2->new(workdir => $dir);
}

subtest 'collector_start IPC -> harness_collector_start event' => sub {
    my $h = mk_harness();

    my @emitted;
    no warnings 'redefine';
    local *Test2::Harness2::Util::EventEmitter::emit_raw = sub {
        my ($self, $event) = @_;
        push @emitted, $event;
        return 'fake-sync';
    };

    $h->{Test2::Harness2::EMITTER()}
        = bless {}, 'Test2::Harness2::Util::EventEmitter';

    my $payload = {
        kind          => 'collector_start',
        type          => 'Run',
        id            => 0,
        run_id        => 0,
        job_id        => undef,
        job_try       => undef,
        service_name  => undef,
        collector_pid => 33333,
        collected_pid => 44444,
        started_at    => 1714875000.123,
        spec          => {run_id => 0, name => 'run-0'},
    };

    $h->run_on_general_message(Test::Harness2::FakeMsg->new($payload));

    is(scalar @emitted, 1, 'one event emitted via emitter');

    my $fd = $emitted[0]{facet_data};
    ok(ref($fd) eq 'HASH', 'event has facet_data');
    my $facet = $fd->{harness_collector_start};
    ok(ref($facet) eq 'HASH', 'harness_collector_start at top level of facet_data');
    is($facet->{kind},          'collector_start', 'kind preserved on facet');
    is($facet->{type},          'Run',             'type=Run preserved');
    is($facet->{id},            0,                 'id preserved');
    is($facet->{run_id},        0,                 'run_id preserved');
    is($facet->{collector_pid}, 33333,             'collector_pid preserved');
    is($facet->{collected_pid}, 44444,             'collected_pid preserved');
    is($facet->{started_at},    1714875000.123,    'started_at preserved');
};

subtest 'collector_end IPC -> harness_collector_end event' => sub {
    my $h = mk_harness();

    my @emitted;
    no warnings 'redefine';
    local *Test2::Harness2::Util::EventEmitter::emit_raw = sub {
        my ($self, $event) = @_;
        push @emitted, $event;
        return 'fake-sync';
    };

    $h->{Test2::Harness2::EMITTER()}
        = bless {}, 'Test2::Harness2::Util::EventEmitter';

    my $payload = {
        kind          => 'collector_end',
        type          => 'Service',
        id            => 'preload-foo',
        run_id        => undef,
        job_id        => undef,
        job_try       => undef,
        service_name  => 'preload-foo',
        collector_pid => 33333,
        collected_pid => 44444,
        exit          => 0,
        exit_decoded  => {err => 0, sig => 0},
        ended_at      => 1714875042.987,
        state         => {exit => 0, ended_at => 1714875042.987},
    };

    $h->run_on_general_message(Test::Harness2::FakeMsg->new($payload));

    is(scalar @emitted, 1, 'one event emitted');

    my $fd = $emitted[0]{facet_data};
    ok(ref($fd) eq 'HASH', 'event has facet_data');
    my $facet = $fd->{harness_collector_end};
    ok(ref($facet) eq 'HASH', 'harness_collector_end at top level of facet_data');
    is($facet->{kind}, 'collector_end',   'kind preserved');
    is($facet->{type}, 'Service',         'type=Service preserved');
    is($facet->{id},           'preload-foo', 'id preserved');
    is($facet->{service_name}, 'preload-foo', 'service_name preserved');
    is($facet->{exit}, 0, 'exit preserved');
    is($facet->{ended_at}, 1714875042.987, 'ended_at preserved');
};

subtest 'no emitter -> handler is a no-op' => sub {
    my $h = mk_harness();
    # No emitter installed; should not crash.
    my $ok = eval {
        $h->run_on_general_message(Test::Harness2::FakeMsg->new({
            kind => 'collector_start',
            type => 'Run', id => 0, run_id => 0,
        }));
        $h->run_on_general_message(Test::Harness2::FakeMsg->new({
            kind => 'collector_end',
            type => 'Run', id => 0, run_id => 0, exit => 0,
        }));
        1;
    };
    ok($ok, 'no-op when emitter missing');
};

done_testing;
