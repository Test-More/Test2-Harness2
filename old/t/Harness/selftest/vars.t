BEGIN { print "1..0 # SKIP only runs under yath (TEST2_HARNESS_ACTIVE)\n" and exit 0 unless $ENV{TEST2_HARNESS_ACTIVE}; }
use Test2::V0;

ok(defined($ENV{$_}), "env var $_ is set") for qw{
    TMPDIR
    HARNESS_ACTIVE
    TEST2_HARNESS_ACTIVE
    TEST2_ACTIVE
    TEST_ACTIVE
    T2_HARNESS_RUN_ID
    T2_HARNESS_JOB_ID
    T2_HARNESS_JOB_IS_TRY
    T2_HARNESS_JOB_FILE
};

done_testing;
