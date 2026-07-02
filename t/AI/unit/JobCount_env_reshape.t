use Test2::V0;
# HARNESS-DURATION-SHORT
# HARNESS-NO-PRELOAD

# Regression coverage for ticket #150 (83): YATH_JOB_COUNT=8:2 arrives via the
# option's from_env_vars, which triggers with action 'initialize' (not 'set').
# The ':' reshape trigger previously bailed unless action eq 'set', so the colon
# form leaked through as a raw "8:2" job_count (numeric-compare warnings, 1 slot
# per test). The trigger now also accepts 'initialize' (mirroring --utilize).

use App::Yath2::Options::Runner;

sub runner_with_env {
    my (%env) = @_;
    local @ENV{keys %env} = values %env;
    my $state = App::Yath2::Options::Runner->options->process_args([], skip_posts => 1);
    return $state->{settings}->runner;
}

subtest 'YATH_JOB_COUNT=8:2 reshapes to job_count 8 / slots_per_job 2' => sub {
    my $warnings = [];
    my $r;
    my $w = warns { $r = runner_with_env(YATH_JOB_COUNT => '8:2') };

    is($r->job_count, 8, "job_count is the pre-colon value (8)");
    ok($r->check_option('slots_per_job'), "slots_per_job side-channel option was created");
    is($r->slots_per_job, 2, "slots_per_job is the post-colon value (2)");
    is($w, 0, "no numeric-compare (or other) warnings from the colon form");
};

subtest 'plain YATH_JOB_COUNT=4 still works (no colon, no slots)' => sub {
    my $r = runner_with_env(YATH_JOB_COUNT => '4');
    is($r->job_count, 4, "plain numeric env job_count passes through");
};

subtest 'CLI -j8:2 still reshapes (action set path unchanged)' => sub {
    my $state = App::Yath2::Options::Runner->options->process_args(['-j', '8:2'], skip_posts => 1);
    my $r = $state->{settings}->runner;
    is($r->job_count, 8, "CLI job_count 8");
    is($r->slots_per_job, 2, "CLI slots_per_job 2");
};

done_testing;
