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

subtest 'lib/blib explicit flags stay additive (do not cross-disable)' => sub {
    my $libs = sub {
        my (@args) = @_;
        my $state = $opts->process_args([@args], skip_posts => 1);
        my $r = $state->{settings}->runner;
        return {
            includes => [@{$r->includes // []}],
            lib      => $r->lib,
            blib     => $r->blib,
        };
    };

    my $def = $libs->();
    is($def->{lib},  1, "lib flag defaults on");
    is($def->{blib}, 1, "blib flag defaults on");
    ok(!(grep { $_ eq 'lib' } @{$def->{includes}}), "no lib path in includes by default");

    my $lib = $libs->('--lib');
    ok((grep { $_ eq 'lib' } @{$lib->{includes}}), "--lib routes 'lib' into includes");
    is($lib->{lib},  0, "--lib suppresses its own flag (path goes via includes)");
    is($lib->{blib}, 1, "--lib does NOT disable blib (regression: was zeroed)");

    my $blib = $libs->('--blib');
    ok((grep { m{blib} } @{$blib->{includes}}), "--blib routes blib paths into includes");
    is($blib->{blib}, 0, "--blib suppresses its own flag");
    is($blib->{lib},  1, "--blib does NOT disable lib (regression: was zeroed)");
};

done_testing;
