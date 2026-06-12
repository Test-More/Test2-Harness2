use strict;
use warnings;
use Test2::V0;

use Test2::Harness2::Plugin;

# ---------------------------------------------------------------------------
# Base defaults
# ---------------------------------------------------------------------------
subtest 'base defaults' => sub {
    my $p = Test2::Harness2::Plugin->new();

    is($p->can_use_globally, 0, "can_use_globally returns 0");
    is($p->can_use_per_run,  0, "can_use_per_run returns 0");
};

# ---------------------------------------------------------------------------
# All lifecycle hooks are no-ops (do not die, return nothing meaningful)
# ---------------------------------------------------------------------------
subtest 'hooks are no-ops' => sub {
    my $p = Test2::Harness2::Plugin->new();

    for my $method (qw/setup teardown tick on_job_queued on_job_complete on_run_queued on_run_complete/) {
        my $ok  = eval { $p->$method(); 1 };
        my $err = $@;
        ok($ok, "$method does not die");
    }
};

# ---------------------------------------------------------------------------
# new() calls init()
# ---------------------------------------------------------------------------
subtest 'new calls init' => sub {

    package My::Plugin::InitCheck;
    use parent 'Test2::Harness2::Plugin';
    sub init { $_[0]->{init_called} = 1 }

    package main;

    my $p = My::Plugin::InitCheck->new();
    ok($p->{init_called}, "init() was called by new()");
};

# ---------------------------------------------------------------------------
# Subclass overriding capabilities
# ---------------------------------------------------------------------------
subtest 'subclass with capabilities' => sub {

    package My::Plugin::Global;
    use parent 'Test2::Harness2::Plugin';
    sub can_use_globally { 1 }
    sub can_use_per_run  { 1 }

    package main;

    my $p = My::Plugin::Global->new();
    is($p->can_use_globally, 1, "subclass can_use_globally returns 1");
    is($p->can_use_per_run,  1, "subclass can_use_per_run returns 1");
};

# ---------------------------------------------------------------------------
# Subclass with functional hooks
# ---------------------------------------------------------------------------
subtest 'subclass with functional hooks' => sub {

    package My::Plugin::Hooks;
    use parent 'Test2::Harness2::Plugin';

    our @log;

    sub setup           { push @My::Plugin::Hooks::log, 'setup' }
    sub teardown        { push @My::Plugin::Hooks::log, 'teardown' }
    sub tick            { push @My::Plugin::Hooks::log, 'tick' }
    sub on_job_queued   { push @My::Plugin::Hooks::log, 'on_job_queued' }
    sub on_job_complete { push @My::Plugin::Hooks::log, 'on_job_complete' }
    sub on_run_queued   { push @My::Plugin::Hooks::log, 'on_run_queued' }
    sub on_run_complete { push @My::Plugin::Hooks::log, 'on_run_complete' }

    package main;

    my $p = My::Plugin::Hooks->new();
    $p->setup();
    $p->teardown();
    $p->tick();
    $p->on_job_queued();
    $p->on_job_complete();
    $p->on_run_queued();
    $p->on_run_complete();

    is(
        \@My::Plugin::Hooks::log,
        [qw/setup teardown tick on_job_queued on_job_complete on_run_queued on_run_complete/],
        "all hooks fire in order"
    );
};

done_testing;
