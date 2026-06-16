use Test2::V0;
use v5.38;

# A2: the `resources` command asks the live runner for its resource status over
# runner.socket via request_handler_resources, instead of constructing an
# observe-mode State that drained the (retired) dispatch.jsonl. This drives the
# handler directly against a minimal consumer of the handlers role with a fake
# canonical State whose resources render fixed status_lines, and asserts the
# rendered { class, lines } records the command prints.

# A fake resource: status_lines returns its prebuilt text (or empty to be skipped,
# matching the command's "next unless lines" behavior).
{
    package My::Res;
    use v5.38;
    use Object::HashBase qw/<lines/;
    sub status_lines ($self) { return $self->{+LINES} }
}

# A fake canonical State exposing just the resources list the handler walks.
{
    package My::State;
    use v5.38;
    use Object::HashBase qw/<resources/;
}

# A minimal consumer of the handlers role: it needs a rootpid slot and a state
# method (the role 'requires' state). Everything else the handler touches is on
# the fake state.
{
    package My::Runner;
    use v5.38;
    use Object::HashBase qw/<rootpid <state/;
    use Role::Tiny::With;
    with 'Test2::Harness2::Runner::Role::Service::Handlers';
}

subtest renders_each_resource => sub {
    my $state = My::State->new(
        resources => [
            My::Res->new(lines => "\n** slots **\nfoo\n"),
            My::Res->new(lines => ''),                       # skipped: empty
            My::Res->new(lines => "\n** ports **\nbar\n"),
        ],
    );

    my $runner = My::Runner->new(rootpid => $$, state => $state);

    my $resp = $runner->request_handler_resources({}, undef);

    ok($resp->{ok}, "handler reports ok");
    is(
        $resp->{resources},
        [
            {class => 'My::Res', lines => "\n** slots **\nfoo\n"},
            {class => 'My::Res', lines => "\n** ports **\nbar\n"},
        ],
        "renders non-empty resources verbatim, skips the empty one",
    );
};

subtest empty_when_no_resources => sub {
    my $runner = My::Runner->new(rootpid => $$, state => My::State->new(resources => []));
    my $resp   = $runner->request_handler_resources({}, undef);
    ok($resp->{ok}, "ok with no resources");
    is($resp->{resources}, [], "empty resource list");
};

subtest not_the_state_hub => sub {
    # A non-root process (e.g. a forked stage service) is not the state authority.
    my $runner = My::Runner->new(rootpid => $$ + 1, state => My::State->new(resources => []));
    my $resp   = $runner->request_handler_resources({}, undef);
    ok(!$resp->{ok}, "declines when not the state hub");
    like($resp->{error}, qr/not the runner state hub/, "explains why");
};

done_testing;
