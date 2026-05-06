use strict;
use warnings;

use Test2::V0;
use Test2::Harness2::RunService;

# Capture emit_event calls without instantiating EventEmitter.
our @captured;

{
    package Test::CapturingEmitter;
    sub new { bless {}, shift }
    sub emit_event {
        my ($self, %fields) = @_;
        push @main::captured, \%fields;
        return 'fake-sync';
    }
}

my $em  = Test::CapturingEmitter->new;
my $svc = bless {
    Test2::Harness2::RunService::EMITTER() => $em,
    Test2::Harness2::RunService::JOB_ID()  => 'svc-job-id',
    Test2::Harness2::RunService::RUN_ID()  => 'r1',
}, 'Test2::Harness2::RunService';

$svc->emit_service_event(some_field => 'value');

is(scalar @captured, 1, 'one event emitted');
ok(!exists $captured[0]{job_try},
    'job_try absent from run-service event payload');
is($captured[0]{run_id},     'r1',         'run_id present');
is($captured[0]{job_id},     'svc-job-id', 'job_id present');
is($captured[0]{some_field}, 'value',      'extra fields preserved');

done_testing;
