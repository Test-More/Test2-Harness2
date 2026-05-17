use strict;
use warnings;

use Test2::V0;

use Test2::Harness2::Role::Preload;

# --- contract: name() is required ---
{
    package MissingName;
    use Role::Tiny::With;
    eval { with 'Test2::Harness2::Role::Preload'; 1 };
    main::ok(!__PACKAGE__->can('name'),
        'consumer without name() composes but cannot satisfy required role method');
}

# A consumer without name() should fail composition at consume time.
{
    eval {
        package WillFail;
        use Role::Tiny::With;
        with 'Test2::Harness2::Role::Preload';
    };
    like($@, qr/name/, 'role composition errors when name() is missing');
}

# --- contract: default hooks are no-ops; do_preload defaults to require ---
{
    package OK::Minimal;
    use Role::Tiny::With;
    sub name    { 'minimal' }
    sub modules { ['strict'] }
    with 'Test2::Harness2::Role::Preload';
}

is(OK::Minimal->name, 'minimal', 'name() returns identifier');
is(OK::Minimal->modules, ['strict'], 'modules() returns arrayref');

# Hooks default to no-op (return undef in list/scalar context).
my $obj = bless {}, 'OK::Minimal';
is($obj->pre_fork,   undef, 'pre_fork is no-op by default');
is($obj->post_fork,  undef, 'post_fork is no-op by default');
is($obj->pre_launch, undef, 'pre_launch is no-op by default');

# do_preload requires the modules listed. 'strict' is core, always loadable.
ok(lives { $obj->do_preload }, 'default do_preload requires modules')
    or note "$@";

# --- failure mode: a bad module surfaces a usable diagnostic ---
{
    package OK::Bad;
    use Role::Tiny::With;
    sub name    { 'bad' }
    sub modules { ['This::Module::Does::Not::Exist::EVER'] }
    with 'Test2::Harness2::Role::Preload';
}
my $bad = bless {}, 'OK::Bad';
my $err = dies { $bad->do_preload };
like(
    $err,
    qr/Failed to load module 'This::Module::Does::Not::Exist::EVER' for preload 'bad'/,
    'do_preload croaks with preload name + module name on failure',
);

# --- modules() must return an arrayref ---
{
    package OK::BadModules;
    use Role::Tiny::With;
    sub name    { 'badmod' }
    sub modules { 'not-an-arrayref' }
    with 'Test2::Harness2::Role::Preload';
}
my $bm = bless {}, 'OK::BadModules';
like(
    dies { $bm->do_preload },
    qr/modules must return an arrayref/,
    'do_preload rejects scalar modules() return',
);

# --- override hooks ---
{
    package OK::Hooks;
    use Role::Tiny::With;
    sub name    { 'hooks' }
    sub modules { [] }

    our %CALLS;
    sub pre_fork   { my ($self, @args) = @_; $CALLS{pre_fork}++;   1 }
    sub post_fork  { my ($self, @args) = @_; $CALLS{post_fork}++;  1 }
    sub pre_launch { my ($self, @args) = @_; $CALLS{pre_launch}++; 1 }
    sub do_preload { my ($self, @args) = @_; $CALLS{do_preload}++; 1 }
    with 'Test2::Harness2::Role::Preload';
}
%OK::Hooks::CALLS = ();
my $h = bless {}, 'OK::Hooks';
$h->pre_fork('svc', {});
$h->post_fork('svc', {});
$h->pre_launch('svc', {});
$h->do_preload('svc');
is(\%OK::Hooks::CALLS, {pre_fork => 1, post_fork => 1, pre_launch => 1, do_preload => 1},
    'consumer overrides win for every hook + do_preload');

done_testing;
