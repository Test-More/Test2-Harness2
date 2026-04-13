use strict;
use warnings;
use Test2::V0;

use Test2::Harness2::Resource;

# ---------------------------------------------------------------------------
# Base class defaults
# ---------------------------------------------------------------------------
subtest 'base defaults' => sub {
    my $r = Test2::Harness2::Resource->new();

    is($r->can_use_globally, 0,     "can_use_globally returns 0");
    is($r->can_use_per_run,  0,     "can_use_per_run returns 0");
    is($r->available,        1,     "available returns 1 by default");
    is($r->applicable,       1,     "applicable returns 1 by default");
    is($r->spawn_service,    undef, "spawn_service returns undef");

    # assign and release are no-ops, should not die
    my $ok  = eval { $r->assign(); 1 };
    my $err = $@;
    ok($ok, "assign does not die");

    $ok  = eval { $r->release(); 1 };
    $err = $@;
    ok($ok, "release does not die");
};

# ---------------------------------------------------------------------------
# Subclass overriding capabilities
# ---------------------------------------------------------------------------
subtest 'subclass with capabilities' => sub {

    package My::Resource::Global;
    use parent 'Test2::Harness2::Resource';
    sub can_use_globally { 1 }
    sub can_use_per_run  { 1 }

    package main;

    my $r = My::Resource::Global->new();
    is($r->can_use_globally, 1, "subclass can_use_globally returns 1");
    is($r->can_use_per_run,  1, "subclass can_use_per_run returns 1");
};

# ---------------------------------------------------------------------------
# Subclass returning available = -1 (permanently broken)
# ---------------------------------------------------------------------------
subtest 'subclass permanently broken' => sub {

    package My::Resource::Broken;
    use parent 'Test2::Harness2::Resource';
    sub available { -1 }

    package main;

    my $r = My::Resource::Broken->new();
    is($r->available, -1, "available returns -1 for permanently broken resource");
};

# ---------------------------------------------------------------------------
# new() calls init()
# ---------------------------------------------------------------------------
subtest 'new calls init' => sub {

    package My::Resource::InitCheck;
    use parent 'Test2::Harness2::Resource';
    sub init { $_[0]->{init_called} = 1 }

    package main;

    my $r = My::Resource::InitCheck->new();
    ok($r->{init_called}, "init() was called by new()");
};

done_testing;
