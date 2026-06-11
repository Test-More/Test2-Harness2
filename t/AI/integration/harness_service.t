use Test2::V0;
use v5.38;

use File::Spec ();
use File::Temp qw/tempdir/;

use lib 't2clib';    # temporary until Test2-Collector is installed

use Test2::Collector::Util::Zstd qw/open_zstd_reader/;
use Test2::Collector::Util::JSON qw/decode_json/;

use Test2::Harness2;
use Test2::Harness2::Run;
use Test2::Harness2::Run::Job;

# End to end: start the harness service (itself wrapped in a non-test
# collector), queue a run over its socket, shut it down, and inspect the
# events files its job collectors wrote into the workdir.

my @incs = map { File::Spec->rel2abs($_) } 'lib', 't2clib';

subtest construction => sub {
    like(
        dies { Test2::Harness2->new() },
        qr/'project' is a required attribute/,
        "project is required",
    );

    like(
        dies { Test2::Harness2->new(project => 'a/b') },
        qr/'project' must not contain a directory separator/,
        "project must be path-safe",
    );

    my $h = Test2::Harness2->new(project => 'myproj');
    like($h->workdir, qr{/t2h2-[^/]+-myproj$}, "default workdir is tmpdir/t2h2-<user>-<project>");
};

subtest full_run => sub {
    my $workdir = tempdir(CLEANUP => 1);
    my $harness = Test2::Harness2->new(project => 'selftest', workdir => $workdir);

    my $pid = $harness->start;
    ok($pid, "started the harness service (pid $pid)");
    ok(-S "$workdir/harness.socket", "the request socket exists");

    my $run = Test2::Harness2::Run->new(
        jobs => [
            {test_file => 't/AI/scripts/collector_pass.pl', includes => \@incs},
            {test_file => 't/AI/scripts/collector_fail.pl', includes => \@incs},
        ],
    );

    $harness->queue_run($run);
    $harness->shutdown;

    is($harness->wait, 0, "the harness service exited cleanly");

    ok(-f "$workdir/harness.jsonl.zst", "the service's own collector recorded an events file");

    my ($pass_job, $fail_job) = @{$run->jobs};
    my $run_dir = "$workdir/" . $run->run_uuid;

    for my $case ([$pass_job, 1, 'passing'], [$fail_job, 0, 'failing']) {
        my ($job, $want_pass, $label) = @$case;

        my $file = "$run_dir/" . $job->job_uuid . "-" . $job->try . ".jsonl.zst";
        ok(-f $file, "events file for the $label job is at <run_uuid>/<job_uuid>-<try>.jsonl.zst");

        my @events = read_events($file);
        ok(@events, "the $label job recorded events");

        my @asserts = grep { $_->{facet_data}{assert} } @events;
        ok(@asserts, "the $label job recorded assertions");

        my $all_passed = (grep { !$_->{facet_data}{assert}{pass} } @asserts) ? 0 : 1;
        is($all_passed, $want_pass, "the $label job's assertions match its verdict");
    }
};

subtest wait_without_start => sub {
    my $h = Test2::Harness2->new(project => 'neverstarted');
    like(dies { $h->wait }, qr/this harness was never started/, "wait without start croaks");
};

sub read_events ($file) {
    my $reader = open_zstd_reader($file);
    my @events;
    while (defined(my $line = $reader->readline)) {
        chomp $line;
        next unless length $line;
        push @events => decode_json($line);
    }
    return @events;
}

done_testing;
