use Test2::V0;
use Data::Dumper ();
use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep time/;

use lib 't/lib';
use Test2::Harness2;
use Test2::Harness2::Resource::Preload;
use App::Yath2::TestFile;

# End-to-end smoke for per-run preloads: the harness spawns without
# any global preload; a Run is queued with a per-run
# Resource::Preload (scope='run'); the test inside that run sees the
# preloaded module via %INC. Validates the Phase 2 wiring that lets
# `yath run -P MyPreload ...` carry preload state through the IPC
# rehydration path.

sub wait_until {
    my ($check, $timeout_sec) = @_;
    my $deadline = time + $timeout_sec;
    while (time < $deadline) {
        return 1 if $check->();
        sleep(0.05);
    }
    return 0;
}

subtest 'per-run preload reaches the test process via %INC' => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $lib = "$dir/lib";
    mkdir $lib;
    mkdir "$lib/PerRunPreloaded";
    open my $mfh, '>', "$lib/PerRunPreloaded/Fixture.pm" or die "$!";
    print $mfh <<'EOM';
package PerRunPreloaded::Fixture;
use strict; use warnings;
our $LOADED = 1;
1;
EOM
    close $mfh;

    my $tf = "$dir/t.t";
    open my $tfh, '>', $tf or die;
    print $tfh <<'EOT';
# HARNESS-PRELOAD: default
use Test2::V0;
ok($INC{'PerRunPreloaded/Fixture.pm'}, 'per-run fixture pre-loaded')
    or diag "INC has: ", join(', ', sort keys %INC);
ok($PerRunPreloaded::Fixture::LOADED, 'fixture global visible');
done_testing;
EOT
    close $tfh;

    push @INC, $lib;

    # Harness has NO global preload. The per-run preload is the only
    # way the fixture module reaches the test.
    my $spawn = Test2::Harness2->spawn(
        workdir      => $dir,
        kill_timeout => 5,
        keep_workdir => 1,
    );

    # Per-run resource: scope='run' is allowed without 'run' at
    # construction; the harness's queue_test_run handler binds it to
    # the Run via set_run().
    my $preload_spec = [
        'Test2::Harness2::Resource::Preload',
        name             => 'default',
        modules          => ['PerRunPreloaded::Fixture'],
        is_role_consumer => 0,
        scope            => 'run',
    ];

    my $q = $spawn->queue_test_run(
        files     => [App::Yath2::TestFile->new(file => $tf)],
        resources => [$preload_spec],
    );
    ok($q->{ok}, 'queued') or diag(Data::Dumper::Dumper($q));

    my $results;
    wait_until(
        sub {
            $results = $spawn->_send_request('run_results', {run_id => $q->{run_id}});
            return defined($results) && defined($results->{pass});
        },
        30,
    ) or do { diag "timed out waiting for run_results"; diag explain $results };

    ok($results && $results->{ok}, 'got run_results');
    is($results->{pass}, 1, 'run passed -- per-run preload reached the test')
        or do {
            diag(Data::Dumper::Dumper($results));
            # Surface the test child's stdout/stderr for debugging
            for my $f (glob "$dir/logs/runs/*/jobs/*/*/events.jsonl*") {
                diag "events from $f";
            }
            # Show captured assertion details
            my $logs = "$dir/logs";
            if (-d $logs) {
                diag "logs dir: " . `find $logs -type f 2>&1 | head -20`;
            }
        };

    $spawn->finish;
    $spawn->wait;
};

done_testing;
