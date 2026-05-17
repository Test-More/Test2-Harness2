use Test2::V0;

use Test2::Harness2::Resource::Preload;

subtest 'construction requires name + modules' => sub {
    my $ok1 = eval { Test2::Harness2::Resource::Preload->new(modules => []) ; 1 };
    ok(!$ok1, 'name required');
    like($@, qr/name/, 'name in error');

    my $ok2 = eval { Test2::Harness2::Resource::Preload->new(name => 'x'); 1 };
    ok(!$ok2, 'modules required');
    like($@, qr/modules/, 'modules in error');

    my $ok3 = eval { Test2::Harness2::Resource::Preload->new(name => 'x', modules => []); 1 };
    ok($ok3, 'name + modules suffices') or diag $@;
};

subtest 'defaults' => sub {
    my $r = Test2::Harness2::Resource::Preload->new(name => 'default', modules => []);
    is($r->resource_name, 'preload:default', 'resource_name namespaced');
    is($r->scope, 'global', 'scope defaults to global');
    ok(!$r->is_usable,            'not usable until host says so');
    ok(!$r->is_permanent_broken,  'not permanent_broken initially');
    is($r->available, 1,          'available always returns 1');
    is($r->needed,    0,          'needed=0 -- resolver picks preloads, not _evaluate_resources_for');
};

subtest 'usability flips with host hook' => sub {
    my $r = Test2::Harness2::Resource::Preload->new(name => 'foo', modules => []);
    $r->mark_ready;
    ok($r->is_usable, 'mark_ready sets usable');
    $r->mark_unusable;
    ok(!$r->is_usable, 'mark_unusable clears it');
};

subtest 'permanent_broken is sticky' => sub {
    my $r = Test2::Harness2::Resource::Preload->new(name => 'foo', modules => []);
    $r->mark_ready;
    $r->mark_permanent_broken;
    ok($r->is_permanent_broken, 'flag set');
    $r->mark_ready;
    ok($r->is_permanent_broken, 'mark_ready does NOT clear permanent_broken');
};

subtest 'mark_broken transient is independent of permanent' => sub {
    my $r = Test2::Harness2::Resource::Preload->new(name => 'foo', modules => []);
    $r->mark_ready;
    $r->mark_broken;
    ok($r->is_broken, 'transient broken flag set');
    ok(!$r->is_permanent_broken, 'permanent unaffected');
    ok(!$r->is_usable, 'transient broken makes it unusable');
    $r->mark_ready;
    ok(!$r->is_broken, 'mark_ready clears transient broken');
};

subtest 'assign / release are no-ops' => sub {
    my $r = Test2::Harness2::Resource::Preload->new(name => 'foo', modules => []);
    my %env;
    my $ok = eval { $r->assign(id => 'a', job => bless({}, 'X'), env => \%env); 1 };
    ok($ok, 'assign returns ok');
    is(\%env, {}, 'assign does not mutate env');

    my $ok2 = eval { $r->release(id => 'a', job => bless({}, 'X')); 1 };
    ok($ok2, 'release returns ok');
};

subtest 'services() returns spec for PreloadService' => sub {
    my $r = Test2::Harness2::Resource::Preload->new(
        name    => 'mypl',
        modules => ['Time::HiRes', 'List::Util'],
    );
    my @services = $r->services;
    is(scalar @services, 1, 'one service entry');
    my ($entry) = @services;
    is($entry->[0], 'Test2::Harness2::PreloadService', 'service class');
    my %args = @{$entry}[1 .. $#$entry];
    is($args{name},    'mypl',                          'name passed');
    is($args{modules}, ['Time::HiRes', 'List::Util'],   'modules passed');
};

done_testing;
