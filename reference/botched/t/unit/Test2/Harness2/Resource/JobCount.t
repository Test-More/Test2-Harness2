use strict;
use warnings;
use Test2::V0;

use Test2::Harness2::Resource::JobCount;

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------
subtest 'construction' => sub {
    my $jc = Test2::Harness2::Resource::JobCount->new(job_count => 4);

    is($jc->job_count, 4, "job_count is set");
    is($jc->_in_use,   0, "_in_use starts at 0");
};

subtest '_in_use defaults to 0 when not provided' => sub {
    my $jc = Test2::Harness2::Resource::JobCount->new(job_count => 2);
    is($jc->_in_use, 0, "_in_use defaults to 0");
};

# ---------------------------------------------------------------------------
# can_use_globally
# ---------------------------------------------------------------------------
subtest 'can_use_globally' => sub {
    my $jc = Test2::Harness2::Resource::JobCount->new(job_count => 1);
    is($jc->can_use_globally, 1, "can_use_globally returns 1");
};

# ---------------------------------------------------------------------------
# available tracks slots
# ---------------------------------------------------------------------------
subtest 'available tracks slots' => sub {
    my $jc = Test2::Harness2::Resource::JobCount->new(job_count => 2);

    is($jc->available, 1, "available when no slots used");

    $jc->assign();
    is($jc->available, 1, "still available after 1 of 2 slots used");

    $jc->assign();
    is($jc->available, 0, "unavailable when all slots filled");
};

# ---------------------------------------------------------------------------
# assign fills slots
# ---------------------------------------------------------------------------
subtest 'assign increments _in_use' => sub {
    my $jc = Test2::Harness2::Resource::JobCount->new(job_count => 3);

    $jc->assign();
    is($jc->_in_use, 1, "_in_use is 1 after one assign");

    $jc->assign();
    is($jc->_in_use, 2, "_in_use is 2 after two assigns");
};

# ---------------------------------------------------------------------------
# release frees slots
# ---------------------------------------------------------------------------
subtest 'release decrements _in_use' => sub {
    my $jc = Test2::Harness2::Resource::JobCount->new(job_count => 2);

    $jc->assign();
    $jc->assign();
    is($jc->available, 0, "full before release");

    $jc->release();
    is($jc->_in_use,   1, "_in_use is 1 after release");
    is($jc->available, 1, "available after release frees a slot");
};

# ---------------------------------------------------------------------------
# release does not go below 0
# ---------------------------------------------------------------------------
subtest 'release does not go below 0' => sub {
    my $jc = Test2::Harness2::Resource::JobCount->new(job_count => 2);

    $jc->release();
    is($jc->_in_use, 0, "_in_use stays at 0 when released with nothing assigned");

    $jc->release();
    is($jc->_in_use, 0, "_in_use still 0 after second spurious release");
};

# ---------------------------------------------------------------------------
# applicable always true
# ---------------------------------------------------------------------------
subtest 'applicable always true' => sub {
    my $jc = Test2::Harness2::Resource::JobCount->new(job_count => 4);
    is($jc->applicable, 1, "applicable returns 1");

    $jc->assign() for 1 .. 4;
    is($jc->applicable, 1, "applicable still 1 when all slots used");
};

# ---------------------------------------------------------------------------
# spawn_service returns undef
# ---------------------------------------------------------------------------
subtest 'no service' => sub {
    my $jc = Test2::Harness2::Resource::JobCount->new(job_count => 1);
    is($jc->spawn_service, undef, "spawn_service returns undef");
};

done_testing;
