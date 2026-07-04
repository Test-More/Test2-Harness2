use Test2::V0;
# HARNESS-DURATION-SHORT
# HARNESS-NO-PRELOAD
#
# Ticket TODO-86: CoverageAggregator::ByTest::finalize() must push the BARE
# in-progress record onto COMPLETED (matching stop_test and every consumer),
# not a wrapper-shaped {testname => record}. The wrapper shape only ever
# surfaced for tests still IN_PROGRESS at harness_final (a bail-out or crash
# between job-start and job-end), so this drives exactly that edge case:
# feed a job-start + coverage event but NO job-end, then finalize and assert
# the bare shape ($final->[0]{test} / {files} populated, not undef).

use strict;
use warnings;

BEGIN {
    eval { require Test2::Harness2::Log::CoverageAggregator::ByTest; 1 }
        or plan skip_all => "Test2::Harness2::Log::CoverageAggregator::ByTest required: $@";
}

my $test = 't/integration/coverage/bail.tx';

my $agg = Test2::Harness2::Log::CoverageAggregator::ByTest->new();

# job-start seeds the IN_PROGRESS record (start_test).
$agg->process_event({
    job_id     => 1,
    facet_data => {
        harness_job_start => {rel_file => $test},
    },
});

# coverage event populates the files hashref via touch(); no job-end follows,
# so the test remains IN_PROGRESS (simulating a bail-out/crash).
$agg->process_event({
    job_id     => 1,
    facet_data => {
        coverage => {
            test  => $test,
            files => {'lib/Foo.pm' => {foo => ['unit']}},
        },
    },
});

my $final = $agg->finalize();

ref_ok($final, 'ARRAY', "finalize returned a list");
ok(@$final == 1, "exactly one completed record");

my $rec = $final->[0];
ref_ok($rec, 'HASH', "record is a bare hashref, not a {testname => rec} wrapper");
is($rec->{test}, $test, "bare record exposes {test} (undef under the old wrapper shape)");
ref_ok($rec->{files}, 'HASH', "bare record exposes a {files} hashref (undef under the old wrapper shape)");
ok(keys %{$rec->{files}}, "{files} is populated with the touched source");

done_testing;
