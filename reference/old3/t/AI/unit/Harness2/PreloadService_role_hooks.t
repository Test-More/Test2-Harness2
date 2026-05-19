use strict;
use warnings;

use Test2::V0;

use Test2::Harness2::PreloadService;

# Fixture: a Role::Preload consumer that records every hook call on a
# class-level @CALLS array.
{
    package T2::Test::Pre::Recorded;
    use Role::Tiny::With;

    our @CALLS;

    sub name    { 'recorded' }
    sub modules { ['strict'] }

    sub do_preload { my ($class, $svc, @rest) = @_; push @CALLS, ['do_preload', ref($svc) || $svc]; 1 }
    sub pre_fork   { my ($class, $svc, $p)    = @_; push @CALLS, ['pre_fork',   ref($svc) || $svc, $p && $p->{job_id}]; 1 }
    sub post_fork  { my ($class, $svc, $p)    = @_; push @CALLS, ['post_fork',  ref($svc) || $svc, $p && $p->{job_id}]; 1 }
    sub pre_launch { my ($class, $svc, $p)    = @_; push @CALLS, ['pre_launch', ref($svc) || $svc, $p && $p->{job_id}]; 1 }

    with 'Test2::Harness2::Role::Preload';
    $INC{'T2/Test/Pre/Recorded.pm'} = __FILE__;
}

subtest '_role_consumer_class returns the class for is_role_consumer=1' => sub {
    my $svc = Test2::Harness2::PreloadService->new(
        name             => 'recorded',
        modules          => ['T2::Test::Pre::Recorded'],
        is_role_consumer => 1,
    );
    is($svc->_role_consumer_class, 'T2::Test::Pre::Recorded',
        'class returned from MODULES[0]');

    my $plain = Test2::Harness2::PreloadService->new(
        name    => 'default',
        modules => ['strict', 'warnings'],
    );
    is($plain->_role_consumer_class, undef,
        'returns undef for non-role-consumer');
};

subtest 'do_preload delegates to consumer class when is_role_consumer=1' => sub {
    @T2::Test::Pre::Recorded::CALLS = ();

    my $svc = Test2::Harness2::PreloadService->new(
        name             => 'recorded',
        modules          => ['T2::Test::Pre::Recorded'],
        is_role_consumer => 1,
    );

    my $ok = eval { $svc->do_preload; 1 };
    ok($ok, 'do_preload succeeded') or diag $@;

    is(\@T2::Test::Pre::Recorded::CALLS,
        [['do_preload', 'Test2::Harness2::PreloadService']],
        'consumer do_preload invoked exactly once with the service as $svc');
};

subtest '_fire_role_hook dispatches to the consumer class with payload' => sub {
    @T2::Test::Pre::Recorded::CALLS = ();

    my $svc = Test2::Harness2::PreloadService->new(
        name             => 'recorded',
        modules          => ['T2::Test::Pre::Recorded'],
        is_role_consumer => 1,
    );

    $svc->_fire_role_hook(pre_fork  => {job_id => 7});
    $svc->_fire_role_hook(post_fork => {job_id => 8});
    $svc->_fire_role_hook(pre_launch => {job_id => 9});

    is(\@T2::Test::Pre::Recorded::CALLS, [
        ['pre_fork',  'Test2::Harness2::PreloadService', 7],
        ['post_fork', 'Test2::Harness2::PreloadService', 8],
        ['pre_launch','Test2::Harness2::PreloadService', 9],
    ], 'hooks invoked in order with payload threaded through');
};

subtest 'non-role-consumer skips hook dispatch entirely' => sub {
    @T2::Test::Pre::Recorded::CALLS = ();

    my $plain = Test2::Harness2::PreloadService->new(
        name    => 'default',
        modules => ['strict'],
    );
    $plain->_fire_role_hook(pre_fork => {job_id => 1});

    is(\@T2::Test::Pre::Recorded::CALLS, [],
        'no hook calls when is_role_consumer is false');
};

subtest 'hook exceptions warn but do not abort' => sub {
    {
        package T2::Test::Pre::Boom;
        use Role::Tiny::With;
        sub name      { 'boom' }
        sub modules   { [] }
        sub pre_fork  { die "synthetic explosion\n" }
        with 'Test2::Harness2::Role::Preload';
        $INC{'T2/Test/Pre/Boom.pm'} = __FILE__;
    }

    my $svc = Test2::Harness2::PreloadService->new(
        name             => 'boom',
        modules          => ['T2::Test::Pre::Boom'],
        is_role_consumer => 1,
    );

    my $captured;
    {
        local $SIG{__WARN__} = sub { $captured = shift };
        my $ok = eval { $svc->_fire_role_hook(pre_fork => {}); 1 };
        ok($ok, '_fire_role_hook returns normally despite the throw inside');
    }
    like($captured, qr/synthetic explosion/, 'hook error surfaces via warn');
    like($captured, qr/preload 'boom'/,       'warn names the preload');
};

done_testing;
