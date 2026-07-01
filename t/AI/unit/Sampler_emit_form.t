use Test2::V0;
use v5.38;

use Test2::Harness2::Service::Sampler;

# Ticket #43 / DB-rewrite: the sampler records each snapshot into its own
# collector event stream as a DURABLE record. It must do so as a structured
# harness_system FACET event (which the default renderer has no render path for),
# NOT as a raw `print STDOUT '{"system_load":...}'` line -- a captured raw line is
# wrapped as an INTERNAL info line and shown to the user (the json-dump bug).

# A fake emitter that records what the sampler hands to emit_raw, so the test
# never touches the real collector event channel (it is itself running under one).
package FakeEmitter {
    sub new   { bless {events => []}, shift }
    sub events { return $_[0]->{events} }
    sub emit_raw { push @{$_[0]->{events}} => $_[1]; return 0 }
}

my $snap = {cpu_pct => 50, mem_pct => 10, load_avg => [0.3, 0.4, 0.5], ncpu => 32, stamp => 1};

subtest 'emits a harness_system facet event (not a raw system_load line)' => sub {
    my $em = FakeEmitter->new;
    my $sampler = Test2::Harness2::Service::Sampler->new(
        workdir       => '/tmp',
        runner_socket => '/tmp/does-not-matter.sock',
        emitter       => $em,
    );

    $sampler->_emit_load_event($snap);

    is(scalar(@{$em->events}), 1, "emitted exactly one structured event");
    is(
        $em->events->[0],
        {facet_data => {harness_system => $snap}},
        "the emitted event is a harness_system facet carrying the snapshot",
    );
    ok(!exists $em->events->[0]->{facet_data}{system_load}, "no legacy 'system_load' envelope key");
};

subtest 'no default emitter outside a collector (would corrupt plain STDOUT)' => sub {
    local $ENV{T2_COLLECTOR_PIPE_COUNT};
    delete $ENV{T2_COLLECTOR_PIPE_COUNT};

    my $sampler = Test2::Harness2::Service::Sampler->new(
        workdir       => '/tmp',
        runner_socket => '/tmp/does-not-matter.sock',
    );

    # Must not die and must not produce an emitter when not collector-wrapped.
    my $ok = eval { $sampler->_emit_load_event($snap); 1 };
    ok($ok, "_emit_load_event is a safe no-op with no collector and no injected emitter");
    is($sampler->{emitter}, undef, "no default emitter was created outside a collector");
};

done_testing;
