use Test2::V0;
use File::Temp qw/tempdir/;
use POSIX qw/:sys_wait_h/;
use Time::HiRes qw/sleep time/;

use lib 't/lib';
use Test2::Harness2;
use Test2::Harness2::Resource::Preload;
use Test2::Harness2::TestFile;

# End-to-end smoke for the preload spawn pathway. Spawns a real
# harness with one Resource::Preload that pre-loads a fixture
# module; queues a test that asserts the module is already in
# %INC; waits for the run to complete; asserts pass.

sub wait_until {
    my ($check, $timeout_sec) = @_;
    my $deadline = time + $timeout_sec;
    while (time < $deadline) {
        return 1 if $check->();
        sleep(0.05);
    }
    return 0;
}

subtest 'yath -P -style preload: test sees preloaded module in %INC' => sub {
    my $dir = tempdir(CLEANUP => 1);

    # Fixture module that records its load into a global so the
    # test inside the preload can check it.
    my $lib = "$dir/lib";
    mkdir $lib;
    mkdir "$lib/Preloaded";
    open my $mfh, '>', "$lib/Preloaded/Fixture.pm" or die "$!";
    print $mfh <<'EOM';
package Preloaded::Fixture;
use strict; use warnings;
our $LOADED = 1;
1;
EOM
    close $mfh;

    # Test that asserts %INC carries the preload-loaded fixture
    # *before* the test itself would have a chance to load it.
    my $tf = "$dir/t.t";
    open my $tfh, '>', $tf or die;
    print $tfh <<'EOT';
use Test2::V0;
ok($INC{'Preloaded/Fixture.pm'}, 'fixture module pre-loaded')
    or diag "INC has: ", join(', ', sort keys %INC);
ok($Preloaded::Fixture::LOADED, 'fixture global visible');
done_testing;
EOT
    close $tfh;

    # PERL5LIB applies at perl startup; setting it now would not
    # change the running interpreter's @INC. Push the fixture dir
    # onto @INC directly so the about-to-be-forked harness (and the
    # preload service it forks in turn) sees the fixture module.
    push @INC, $lib;

    my $preload = Test2::Harness2::Resource::Preload->new(
        name    => 'default',
        modules => ['Preloaded::Fixture'],
    );

    my $spawn = Test2::Harness2->spawn(
        workdir      => $dir,
        resources    => [$preload],
        kill_timeout => 5,
    );

    my $q = $spawn->queue_test_run(files => [Test2::Harness2::TestFile->new(file => $tf)]);
    ok($q->{ok}, 'queued') or diag explain $q;

    # Wait for the run to finalize (run_results returns a pass field).
    my $results;
    wait_until(
        sub {
            $results = $spawn->_send_request('run_results', { run_id => $q->{run_id} });
            return defined($results) && defined($results->{pass});
        },
        30,
    ) or do { diag "timed out waiting for run_results"; diag explain $results };

    ok($results && $results->{ok}, 'got run_results');
    is($results->{pass}, 1, 'run passed -- preload reached the test')
        or diag explain $results;

    $spawn->finish;
    $spawn->wait;
};

done_testing;
