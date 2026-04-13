use Test2::V0;

use Test2::Harness2::Renderer;

# ---- produces_terminal_output default ----
subtest 'produces_terminal_output default is false' => sub {
    my $r = Test2::Harness2::Renderer->new();
    ok(!$r->produces_terminal_output, "produces_terminal_output returns false by default");
};

# ---- render_event NOT defined in base ----
subtest 'render_event not defined in base class' => sub {
    ok(!Test2::Harness2::Renderer->can('render_event'), "render_event is not defined in base class");
};

# ---- has_render_event detection ----
subtest 'has_render_event detection' => sub {
    {

        package My::RendererWithEvent;
        use base 'Test2::Harness2::Renderer';
        sub render_event { 1 }
    }

    {

        package My::RendererWithoutEvent;
        use base 'Test2::Harness2::Renderer';
        # no render_event
    }

    ok(
        Test2::Harness2::Renderer::has_render_event('My::RendererWithEvent'),
        "has_render_event true for subclass with render_event"
    );

    ok(
        !Test2::Harness2::Renderer::has_render_event('My::RendererWithoutEvent'),
        "has_render_event false for subclass without render_event"
    );

    ok(
        !Test2::Harness2::Renderer::has_render_event('Test2::Harness2::Renderer'),
        "has_render_event false for base class itself"
    );
};

# ---- has_render_event caching ----
subtest 'has_render_event is cached per class' => sub {
    {

        package My::CacheTest;
        use base 'Test2::Harness2::Renderer';
        sub render_event { 1 }
    }

    my $first  = Test2::Harness2::Renderer::has_render_event('My::CacheTest');
    my $second = Test2::Harness2::Renderer::has_render_event('My::CacheTest');
    ok($first,  "first call returns true");
    ok($second, "second call returns true");
};

# ---- start and finish hooks exist ----
subtest 'start and finish hooks exist' => sub {
    my $r = Test2::Harness2::Renderer->new();
    ok($r->can('start'),  "start() method exists");
    ok($r->can('finish'), "finish() method exists");

    # Should not die when called
    my $ok  = eval { $r->start(log_file => '/tmp/fake.jsonl', per_test => 1); 1 };
    my $err = $@;
    ok($ok, "start() does not die") or diag($err);

    $ok  = eval { $r->finish(log_file => '/tmp/fake.jsonl', per_test => 1); 1 };
    $err = $@;
    ok($ok, "finish() does not die") or diag($err);
};

# ---- new() constructor ----
subtest 'new() constructor works' => sub {
    my $r = Test2::Harness2::Renderer->new();
    isa_ok($r, 'Test2::Harness2::Renderer');
};

done_testing;
