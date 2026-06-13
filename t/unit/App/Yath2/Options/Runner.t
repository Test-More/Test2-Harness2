use Test2::V0;
# HARNESS-DURATION-SHORT
# HARNESS-NO-PRELOAD

use App::Yath2::Options::Runner;

my $opts = App::Yath2::Options::Runner->options;

subtest 'fail_on_resource_skip option is defined' => sub {
    my @all = @{$opts->options};
    my ($opt) = grep { $_->field eq 'fail_on_resource_skip' } @all;

    ok($opt, "fail_on_resource_skip option exists");
    isa_ok($opt, ['Getopt::Yath::Option::Bool'], "Option is a boolean type");
    is($opt->group, 'runner', "Option is in the runner group");
    is($opt->field, 'fail_on_resource_skip', "Field name is fail_on_resource_skip");
    like($opt->description, qr/resource-skipped tests as failures/, "Description mentions resource-skipped tests");
};

subtest 'fail_on_resource_skip default in settings' => sub {
    my $state    = $opts->process_args([], skip_posts => 1);
    my $settings = $state->{settings};

    ok($settings->check_group('runner'), "runner group is defined");
    is($settings->runner->fail_on_resource_skip, 0, "Default value is 0 (skip, not fail)");
};

done_testing;
