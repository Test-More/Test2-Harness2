use Test2::V0;
# HARNESS-DURATION-SHORT
# HARNESS-NO-PRELOAD

use App::Yath2::Options::Runner;

my $opts = App::Yath2::Options::Runner->options;

subtest 'fail_on_resource_skip option is defined' => sub {
    my @all = @{$opts->all};
    my ($opt) = grep { $_->field eq 'fail_on_resource_skip' } @all;

    ok($opt, "fail_on_resource_skip option exists");
    is($opt->type, 'b', "Option is a boolean type");
    is($opt->default, 0, "Default is 0 (off)");
    like($opt->description, qr/resource-skipped tests as failures/, "Description mentions resource-skipped tests");
    is($opt->prefix, 'runner', "Option is in the runner prefix");
    is($opt->field, 'fail_on_resource_skip', "Field name is fail_on_resource_skip");
};

subtest 'fail_on_resource_skip default in settings' => sub {
    my ($opt) = grep { $_->field eq 'fail_on_resource_skip' } @{$opts->all};
    my $settings = $opts->settings;

    # option_slot defines the prefix and vivifies the field
    my $slot = $opt->option_slot($settings);
    my $default = $opt->get_default($settings);
    $$slot //= $default;

    ok($settings->check_prefix('runner'), "runner prefix is defined");
    is($settings->runner->fail_on_resource_skip, 0, "Default value is 0 (skip, not fail)");
};

done_testing;
