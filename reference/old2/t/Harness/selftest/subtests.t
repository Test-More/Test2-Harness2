#!/usr/bin/perl
# HARNESS-DURATION-MEDIUM

BEGIN { print "1..0 # SKIP only runs under yath (TEST2_HARNESS_ACTIVE)\n" and exit 0 unless $ENV{TEST2_HARNESS_ACTIVE}; }
use Test2::V0;
use Time::HiRes qw/sleep/;
use Test2::Tools::AsyncSubtest;

ok(1, "pass");

my $astA = async_subtest 'ast A';

$astA->run(sub { ok(1, "ast A 1") });

subtest out => sub {
    ok(1, "pass");
    ok(1, "pass");

    my $astB = async_subtest 'ast B';

    $astB->run(sub { ok(1, "ast B 1") });
    $astA->run(sub { ok(1, "ast A 2") });

    $astB->finish;

    subtest in => sub {
        for (1 .. 10) {
            ok(1, "pass $_");
            sleep 0.1;
        }
    };

    ok(1, "pass");
    ok(1, "pass");
};

$astA->finish;

done_testing;
