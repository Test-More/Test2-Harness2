use Test2::V0;

# Try ordinals are 1-based (R10 / TODO-49): the first attempt is is_try == 1, so a
# retry is is_try > 1.
ok(($ENV{T2_HARNESS_JOB_IS_TRY} // 0) > 1, "Not the first try");

done_testing;
