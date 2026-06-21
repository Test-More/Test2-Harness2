use Test2::V0;
use v5.38;

# Review P2: `yath spawn` submits its spawn over runner.socket as an ACKNOWLEDGED
# (two-way) request so a spawn aimed at a stage that does not exist / is not a live
# preload service fails promptly, instead of the command blindly waiting on its
# worker tempfile (whose read timeout is long). This drives
# request_handler_queue_spawn directly against a minimal consumer of the handlers
# role with a fake canonical State, asserting the positive/negative ack shape.

# A fake canonical State: spawn_stage_ready resolves the stage and reports whether
# a live stage is available; queue_spawn records the queued spawn.
{
    package My::State;
    use v5.38;
    use Object::HashBase qw/<ready_stages <queued/;

    sub spawn_stage_ready ($self, $spawn) {
        my $stage = $spawn->{stage} // 'default';
        my $ready = ($self->{+READY_STAGES} // {})->{$stage} ? 1 : 0;
        return ($stage, $ready);
    }

    sub queue_spawn ($self, $spawn) {
        push @{$self->{+QUEUED} //= []} => $spawn;
        return;
    }
}

# A minimal consumer of the handlers role: it needs a rootpid slot and a state
# method (the role 'requires' state).
{
    package My::Runner;
    use v5.38;
    use Object::HashBase qw/<rootpid <state <settings/;
    use Role::Tiny::With;
    with 'Test2::Harness2::Runner::Role::Service::Handlers';
}

subtest accepts_when_live_stage => sub {
    my $state  = My::State->new(ready_stages => {default => 1});
    my $runner = My::Runner->new(rootpid => $$, state => $state);

    my $resp = $runner->request_handler_queue_spawn(
        {spawn => {stage => 'default', file => 'foo.pl'}},
        undef,
    );

    ok($resp->{ok},      "spawn accepted");
    ok($resp->{queued},  "spawn reported queued");
    is($resp->{stage}, 'default', "acks the resolved stage");
    is(scalar(@{$state->queued}), 1, "spawn was queued in state");
};

subtest rejects_when_no_live_stage => sub {
    # The target stage is not a live ready preload service: fail fast with a clear
    # ack instead of queuing a spawn nothing will run (which would hang the command
    # on the worker tempfile).
    my $state  = My::State->new(ready_stages => {});
    my $runner = My::Runner->new(rootpid => $$, state => $state);

    my $resp = $runner->request_handler_queue_spawn(
        {spawn => {stage => 'missing', file => 'foo.pl'}},
        undef,
    );

    ok(!$resp->{ok}, "spawn rejected");
    is($resp->{stage}, 'missing', "names the resolved stage");
    like($resp->{error}, qr/No live preload stage 'missing'/, "explains why");
    is($state->queued, undef, "nothing queued in state");
};

subtest not_the_state_hub => sub {
    # A non-root process (a forked stage service) is not the state authority.
    my $state  = My::State->new(ready_stages => {default => 1});
    my $runner = My::Runner->new(rootpid => $$ + 1, state => $state);

    my $resp = $runner->request_handler_queue_spawn(
        {spawn => {stage => 'default', file => 'foo.pl'}},
        undef,
    );

    ok(!$resp->{ok}, "declines when not the state hub");
    like($resp->{error}, qr/not the runner state hub/, "explains why");
    is($state->queued, undef, "nothing queued");
};

done_testing;
