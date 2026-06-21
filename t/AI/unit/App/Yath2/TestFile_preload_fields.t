use v5.38;
use Test2::V0 -target => 'App::Yath2::TestFile';

use ok $CLASS;

use Test2::Tools::GenTemp qw/gen_temp/;

# Covers the client-side preload field production (ARCHITECTURE.md §4.7a):
# the three queue-item fields no_preload / require_preload / preload_list,
# their directives, the validation rule, and plugin overrides via munge_files.

my $tmp = gen_temp(
    plain        => "use strict;\n",
    no_preload   => "# HARNESS-NO-PRELOAD\n",
    stage_one    => "# HARNESS-STAGE Foo\n",
    stage_many   => "# HARNESS-STAGE A B C\n",
    stage_req    => "# HARNESS-STAGE-REQUIRE A B C\n",
    stage_dash   => "#HARNESS-STAGE-FoO\n",
    bad_combo    => "# HARNESS-NO-PRELOAD\n# HARNESS-STAGE A B\n",
);

sub tf ($name) { $CLASS->new(file => File::Spec->catfile($tmp, $name)) }

subtest defaults_no_directive => sub {
    my $task = tf('plain')->queue_item(1);
    is($task->{no_preload},      0,  "no_preload off by default");
    is($task->{require_preload}, 0,  "require_preload off by default");
    is($task->{preload_list},    [], "preload_list empty by default");
    is($task->{stage},           undef, "stage undef by default");
};

subtest harness_no_preload => sub {
    my $one = tf('no_preload');
    is($one->check_no_preload,      1,  "check_no_preload true");
    is($one->check_require_preload, 0,  "require_preload false");
    is($one->check_preload_list,    [], "preload_list empty");

    my $task = $one->queue_item(1);
    is($task->{no_preload},      1,  "no_preload field set from directive");
    is($task->{require_preload}, 0,  "require_preload off");
    is($task->{preload_list},    [], "preload_list empty");
    is($task->{use_preload},     0,  "legacy use_preload still off");
};

subtest harness_stage_single => sub {
    my $one = tf('stage_one');
    is($one->check_preload_list, ['Foo'], "single arg -> 1-element list");
    is($one->check_require_preload, 0, "advisory (not required)");
    is($one->check_stage, 'Foo', "legacy stage back-compat preserved");

    my $task = $one->queue_item(1);
    is($task->{preload_list}, ['Foo'], "preload_list field");
    is($task->{stage},        'Foo',   "legacy stage field still populated");
    is($task->{no_preload},   0,       "no_preload off");
};

subtest harness_stage_dash_single => sub {
    # Back-compat: the old dash-delimited single-stage form.
    my $one = tf('stage_dash');
    is($one->check_stage, 'FoO', "dash form, case preserved");
    is($one->check_preload_list, ['FoO'], "dash form -> 1-element list");
};

subtest harness_stage_multi => sub {
    my $one = tf('stage_many');
    is($one->check_preload_list, ['A', 'B', 'C'], "multi-arg ordered list");
    is($one->check_require_preload, 0, "advisory");

    my $task = $one->queue_item(1);
    is($task->{preload_list}, ['A', 'B', 'C'], "ordered preload_list field");
    is($task->{stage}, 'A', "legacy stage = first list element");
};

subtest harness_stage_require => sub {
    my $one = tf('stage_req');
    is($one->check_require_preload, 1, "REQUIRE keyword -> require_preload");
    is($one->check_preload_list, ['A', 'B', 'C'], "REQUIRE stripped from list");

    my $task = $one->queue_item(1);
    is($task->{require_preload}, 1, "require_preload field set");
    is($task->{preload_list}, ['A', 'B', 'C'], "list without REQUIRE");
    is($task->{stage}, 'A', "legacy stage = first list element");
};

subtest validation_directive_conflict => sub {
    my $one = tf('bad_combo');
    like(
        dies { $one->queue_item(1) },
        qr/cannot combine a no-preload directive/,
        "no_preload + stage list is rejected",
    );
};

subtest plugin_override_munge_files => sub {
    # munge_files is the queue-time plugin hook: a plugin sets/clears the
    # three fields on the App::Yath2::TestFile object before queue_item.
    my $one = tf('plain');
    $one->set_preload_list(['X', 'Y']);
    $one->set_require_preload(1);

    my $task = $one->queue_item(1);
    is($task->{preload_list},    ['X', 'Y'], "plugin-set list flows to task");
    is($task->{require_preload}, 1,          "plugin-set require flows to task");
    is($task->{no_preload},      0,          "no_preload off");
    is($task->{stage},           'X',        "legacy stage filled from plugin list");

    # Plugin sets no_preload, clearing the stage intent.
    my $two = tf('stage_many');
    $two->set_no_preload(1);
    $two->set_require_preload(0);
    $two->set_preload_list([]);
    my $task2 = $two->queue_item(1);
    is($task2->{no_preload},   1,  "plugin forced no_preload");
    is($task2->{preload_list}, [], "plugin cleared list");
};

subtest plugin_override_revalidates => sub {
    # A plugin override that violates the rule is caught at queue time.
    my $one = tf('plain');
    $one->set_no_preload(1);
    $one->set_preload_list(['Z']);
    like(
        dies { $one->queue_item(1) },
        qr/cannot combine a no-preload directive/,
        "plugin override is re-validated",
    );
};

done_testing;
