use Test2::V0;
use File::Temp qw/tempdir/;

use lib 't/lib';
use Test2::Harness2;
use Test2::Harness2::Resource::Preload;

{
    package Test::Harness2::FakeMsg;
    sub new     { my ($c, $body) = @_; bless {body => $body}, $c }
    sub content { $_[0]->{body} }
    sub from    { 'fake-peer' }
}

sub mk_harness {
    my (%opts) = @_;
    my $dir = tempdir(CLEANUP => 1);
    return Test2::Harness2->new(workdir => $dir, %opts);
}

subtest 'preload_ready flips global Resource::Preload to usable' => sub {
    my $r = Test2::Harness2::Resource::Preload->new(name => 'default', modules => []);
    my $h = mk_harness(resources => [$r]);

    ok(!$r->is_usable, 'not usable initially');

    $h->run_on_general_message(Test::Harness2::FakeMsg->new({
        kind         => 'preload_ready',
        preload_name => 'default',
        scope        => 'global',
    }));

    ok($r->is_usable, 'usable after preload_ready');
};

subtest 'preload_broken flips usable -> transient broken' => sub {
    my $r = Test2::Harness2::Resource::Preload->new(name => 'foo', modules => []);
    $r->mark_ready;
    my $h = mk_harness(resources => [$r]);

    $h->run_on_general_message(Test::Harness2::FakeMsg->new({
        kind         => 'preload_broken',
        preload_name => 'foo',
        scope        => 'global',
    }));

    ok($r->is_broken,  'transient broken set');
    ok(!$r->is_usable, 'no longer usable');
    ok(!$r->is_permanent_broken, 'not permanent');
};

subtest 'preload_ready clears transient broken' => sub {
    my $r = Test2::Harness2::Resource::Preload->new(name => 'foo', modules => []);
    $r->mark_broken;
    my $h = mk_harness(resources => [$r]);

    $h->run_on_general_message(Test::Harness2::FakeMsg->new({
        kind         => 'preload_ready',
        preload_name => 'foo',
        scope        => 'global',
    }));

    ok(!$r->is_broken, 'transient cleared');
    ok($r->is_usable,  'usable');
};

subtest 'permanent_broken sticks across preload_ready' => sub {
    my $r = Test2::Harness2::Resource::Preload->new(name => 'foo', modules => []);
    $r->mark_permanent_broken;
    my $h = mk_harness(resources => [$r]);

    $h->run_on_general_message(Test::Harness2::FakeMsg->new({
        kind         => 'preload_ready',
        preload_name => 'foo',
        scope        => 'global',
    }));

    ok($r->is_permanent_broken, 'permanent_broken still set');
    ok(!$r->is_usable,          'still not usable');
};

subtest 'run-scoped preload_ready matches by run_id' => sub {
    my $fake_run = bless { run_id => 'R1' }, 'Test2::Harness2::Test::FakeRun';
    no strict 'refs';
    *Test2::Harness2::Test::FakeRun::run_id = sub { $_[0]->{run_id} };
    use strict 'refs';

    my $rr = Test2::Harness2::Resource::Preload->new(
        name    => 'foo',
        modules => [],
        scope   => 'run',
        run     => $fake_run,
    );
    my $gr = Test2::Harness2::Resource::Preload->new(
        name    => 'foo',
        modules => [],
    );
    my $h = mk_harness(resources => [$gr, $rr]);

    $h->run_on_general_message(Test::Harness2::FakeMsg->new({
        kind         => 'preload_ready',
        preload_name => 'foo',
        scope        => 'run',
        run_id       => 'R1',
    }));

    ok($rr->is_usable,  'run-scoped preload becomes usable');
    ok(!$gr->is_usable, 'global preload untouched');
};

subtest 'unknown preload name is a no-op' => sub {
    my $r = Test2::Harness2::Resource::Preload->new(name => 'foo', modules => []);
    my $h = mk_harness(resources => [$r]);

    my $ok = eval {
        $h->run_on_general_message(Test::Harness2::FakeMsg->new({
            kind         => 'preload_ready',
            preload_name => 'nonexistent',
            scope        => 'global',
        }));
        1;
    };
    ok($ok, 'no crash on unknown preload') or diag $@;
    ok(!$r->is_usable, 'matching preload untouched');
};

done_testing;
