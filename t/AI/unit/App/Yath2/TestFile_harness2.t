use v5.38;
use Test2::V0 -target => 'App::Yath2::TestFile';

use ok $CLASS;

use Test2::Tools::GenTemp qw/gen_temp/;

# Ticket #58: App::Yath2::TestFile drives the new HARNESS2: grammar parser
# (Test2::Harness2::Util::Directives) and the legacy compat parser
# (Test2::Harness2::Util::Directives::Legacy), mapping either onto the harness
# fields. Covers: HARNESS2 structural directives, HARNESS2-wins precedence
# (legacy ignored silently, E2), the block form keeping the header scan alive,
# and parse-error -> synthetic-failure task (E1).

my $tmp = gen_temp(
    h2_basic => join("\n",
        "#!/usr/bin/perl",
        "# HARNESS2: category dbtest",
        "# HARNESS2: duration long",
        "# HARNESS2: timeout.event 30",
        "# HARNESS2: timeout.postexit 60",
        "# HARNESS2: retry.count 2",
        "# HARNESS2: retry.isolated \@on",
        "# HARNESS2: conflicts db redis",
        "# HARNESS2: conflicts cache",
        "# HARNESS2: slots 2 8",
        "# HARNESS2: stage worker",
        "# HARNESS2: smoke \@on",
        "# HARNESS2: fork \@off",
        "use strict;",
        "",
    ),

    # HARNESS2 present -> legacy HARNESS- lines ignored silently (E2).
    h2_wins => join("\n",
        "# HARNESS2: category alpha",
        "# HARNESS-CATEGORY-BETA",
        "# HARNESS-RETRY 9",
        "use strict;",
        "",
    ),

    # Block form: the scan must not stop at the code inside the block.
    h2_block => join("\n",
        "# HARNESS2: churn {",
        "sub heavy { 1 }",
        "# HARNESS2: churn }",
        "# HARNESS2: stage afterblock",
        "use strict;",
        "",
    ),

    # E1 cases.
    bad_quote => qq{# HARNESS2: meta.x "open\nuse strict;\n},
    bad_block => join("\n",
        "# HARNESS2: churn {",
        "# HARNESS2: other }",
        "use strict;",
        "",
    ),

    good_legacy => "# HARNESS-CATEGORY-FOO\nuse strict;\n",
);

sub tf ($name) { $CLASS->new(file => File::Spec->catfile($tmp, $name)) }

subtest harness2_structural_fields => sub {
    my $one = tf('h2_basic');

    is($one->check_category,     'dbtest', "category from HARNESS2");
    is($one->check_duration,     'long',   "duration from HARNESS2");
    is($one->event_timeout,      30,       "timeout.event");
    is($one->post_exit_timeout,  60,       "timeout.postexit");
    is($one->retry,              2,        "retry.count");
    is($one->retry_isolated,     1,        "retry.isolated");
    is([sort @{$one->conflicts_list}], ['cache', 'db', 'redis'], "conflicts merged + lc");
    is($one->check_min_slots,    2,        "min slots");
    is($one->check_max_slots,    8,        "max slots");
    is($one->check_stage,        'worker', "stage");
    is($one->check_feature('smoke'), 1,    "smoke feature on");
    is($one->check_feature('fork'),  0,    "fork feature off");

    my $task = $one->queue_item(7);
    is($task->{category},   'dbtest', "task category");
    is($task->{duration},   'long',   "task duration");
    is($task->{event_timeout}, 30,    "task event_timeout");
    is($task->{retry},      2,        "task retry");
    ok(!defined($task->{directive_error}), "no directive_error on a valid file");
};

subtest harness2_wins_legacy_ignored => sub {
    my $one = tf('h2_wins');
    is($one->check_category, 'alpha', "HARNESS2 category wins");
    # legacy HARNESS-RETRY 9 must be ignored
    my $task = $one->queue_item(1);
    ok(!exists($task->{retry}) || !$task->{retry}, "legacy HARNESS-RETRY ignored when HARNESS2 present");
};

subtest harness2_block_keeps_scan_alive => sub {
    my $one = tf('h2_block');
    is($one->check_stage, 'afterblock', "directive after a closed block is still scanned");
};

subtest legacy_still_works => sub {
    my $one = tf('good_legacy');
    is($one->check_category, 'foo', "legacy HARNESS-CATEGORY parsed when no HARNESS2");
};

subtest parse_error_synthetic_failure => sub {
    my $bad = tf('bad_quote');
    ok(defined $bad->directive_error, "bad quote marks the file invalid");
    like($bad->directive_error, qr/unterminated quote/, "error mentions the cause");

    my $task = $bad->queue_item(1, 'run-x');
    ok(defined $task->{directive_error}, "queued task carries directive_error");
    like($task->{directive_error}, qr/unterminated quote/, "error message preserved");
    is($task->{file}, $bad->file, "task still names the file");
    ok(defined $task->{job_id}, "task has a job_id (queueing did not abort)");

    my $bad2 = tf('bad_block');
    my $task2 = $bad2->queue_item(2, 'run-x');
    like($task2->{directive_error}, qr/block close key mismatch/, "mismatched block -> error");
};

subtest mixed_good_and_bad_run => sub {
    # Discovery of a mix of good + bad files must not abort: each file produces a
    # task; the bad ones carry directive_error, the good ones do not.
    my @tasks = map { tf($_)->queue_item(1, 'run-mix') } qw/h2_basic bad_quote good_legacy bad_block/;
    is(scalar(@tasks), 4, "all four files produced a task");
    ok(!$tasks[0]->{directive_error}, "h2_basic ok");
    ok($tasks[1]->{directive_error},  "bad_quote failed");
    ok(!$tasks[2]->{directive_error}, "good_legacy ok");
    ok($tasks[3]->{directive_error},  "bad_block failed");
};

done_testing;
