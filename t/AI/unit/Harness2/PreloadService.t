use Test2::V0;

use Test2::Harness2::PreloadService;

subtest 'role composition' => sub {
    ok(
        Role::Tiny::does_role('Test2::Harness2::PreloadService', 'Test2::Harness2::Role::Service'),
        'consumes Role::Service',
    );
    ok(
        Role::Tiny::does_role('Test2::Harness2::PreloadService', 'Test2::Harness2::Role::ResourceService'),
        'consumes Role::ResourceService',
    );
    ok(
        Role::Tiny::does_role('Test2::Harness2::PreloadService', 'IPC::Manager::Role::Service'),
        'consumes IPC::Manager::Role::Service',
    );
};

subtest 'construction requires name + modules' => sub {
    my $ok1 = eval { Test2::Harness2::PreloadService->new(modules => []); 1 };
    ok(!$ok1, 'name required');
    like($@, qr/name/, 'name in error');

    my $ok2 = eval { Test2::Harness2::PreloadService->new(name => 'x'); 1 };
    ok(!$ok2, 'modules required');
    like($@, qr/modules/, 'modules in error');

    my $ok3 = eval {
        Test2::Harness2::PreloadService->new(name => 'x', modules => []);
        1;
    };
    ok($ok3, 'name + modules suffices') or diag $@;
};

subtest 'defaults' => sub {
    my $s = Test2::Harness2::PreloadService->new(name => 'default', modules => []);
    is($s->name, 'preload-default', 'name is namespaced');
    is($s->preload_name, 'default', 'preload_name accessor');
    is($s->scope, 'global', 'scope defaults to global');
    is($s->modules, [], 'modules accessor');
    is($s->is_role_consumer, 0, 'is_role_consumer defaults false');
    ok($s->restartable, 'auto-restartable by default');
};

subtest 'run scope' => sub {
    my $s = Test2::Harness2::PreloadService->new(
        name    => 'pl',
        modules => [],
        scope   => 'run',
        run_id  => 'RUNUUID',
    );
    is($s->scope, 'run', 'scope=run');
    is($s->run_id, 'RUNUUID', 'run_id stored');
    is($s->name, 'preload-RUNUUID-pl', 'run-scoped name');
};

subtest 'service_started_fields carry preload identity' => sub {
    my $s = Test2::Harness2::PreloadService->new(
        name             => 'mypl',
        modules          => ['List::Util'],
        is_role_consumer => 1,
    );
    my %fields = $s->service_started_fields;
    is($fields{preload_name},     'mypl',           'preload_name');
    is($fields{preload_scope},    'global',         'preload_scope');
    is($fields{preload_modules},  ['List::Util'],   'preload_modules');
    is($fields{is_role_consumer}, 1,                'is_role_consumer flag');
    ok(!exists $fields{preload_run_id}, 'no preload_run_id when global');

    my $r = Test2::Harness2::PreloadService->new(
        name    => 'mypl',
        modules => [],
        scope   => 'run',
        run_id  => 'RUNUUID',
    );
    my %rf = $r->service_started_fields;
    is($rf{preload_scope},  'run',     'run scope');
    is($rf{preload_run_id}, 'RUNUUID', 'run_id present');
};

subtest 'role contract accessors present' => sub {
    my $s = Test2::Harness2::PreloadService->new(
        name     => 'x',
        modules  => [],
        log_path => '/tmp/x.jsonl',
    );
    can_ok($s, [qw/workdir name kill_timeout watch_pids set_state set_own_pgroup
                   hard_stop_pids emit_service_event ipcm_info pid set_pid orig_io
                   handle_request/], 'required accessors present');
    is($s->kill_timeout, 15, 'default kill_timeout');
    is($s->workdir, '/tmp', 'workdir derives from log_path dirname');
    is([$s->hard_stop_pids], [], 'hard_stop_pids returns empty list with no children');
};

done_testing;
