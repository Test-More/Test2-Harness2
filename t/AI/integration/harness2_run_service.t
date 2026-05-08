use Test2::V0;
use File::Temp qw/tempdir/;
use Time::HiRes qw/time sleep/;

use lib 't/lib';
use Test2::Harness2;
use Test2::Harness2::TestFile;
use Test2::Harness2::Test::SpawnRace qw/finish_and_wait/;

use App::Yath2::Log;

sub wait_until {
    my ($check, $timeout_sec) = @_;
    my $deadline = time + $timeout_sec;
    while (time < $deadline) {
        return 1 if $check->();
        sleep(0.05);
    }
    return 0;
}

subtest 'run service writes its own collector trio under runs/<run_id>/' => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $tf = "$dir/ok.t";
    open my $fh, '>', $tf or die $!;
    print $fh "use Test2::V0; ok(1); done_testing;\n";
    close $fh;

    my $spawn = Test2::Harness2->spawn(workdir => $dir);
    my $q = $spawn->queue_test_run(files => [Test2::Harness2::TestFile->new(file => $tf)]);
    ok($q->{ok}, 'queued') or diag explain $q;

    wait_until(
        sub {
            my $s = $spawn->status;
            return !@{$s->{queue}} && !@{$s->{running} // []};
        },
        15,
    ) or die "run did not drain";

    finish_and_wait($spawn);

    # Use the Log API to inspect the on-disk tree.
    my $log = App::Yath2::Log->new(dir => "$dir/logs");
    my @runs = $log->runs;
    is(scalar(@runs), 1, 'one run directory written');
    my $run_id = $runs[0];

    my $run_a = $log->artifacts($run_id);
    ok(length($run_a->spec) > 0,   'run spec.jsonl(.zst) is non-empty');
    ok(length($run_a->report) > 0, 'run report.jsonl(.zst) is non-empty');
};

subtest 'harness service has its own collector trio' => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $tf = "$dir/ok.t";
    open my $fh, '>', $tf or die $!;
    print $fh "use Test2::V0; ok(1); done_testing;\n";
    close $fh;

    my $spawn = Test2::Harness2->spawn(workdir => $dir);
    $spawn->queue_test_run(files => [Test2::Harness2::TestFile->new(file => $tf)]);

    wait_until(
        sub {
            my $s = $spawn->status;
            return !@{$s->{queue}} && !@{$s->{running} // []};
        },
        15,
    ) or die "run did not drain";

    finish_and_wait($spawn);

    my $log = App::Yath2::Log->new(dir => "$dir/logs");
    ok($log->has_service('harness'), 'harness service present');
    my $harn_a = $log->artifacts('harness');
    ok(length($harn_a->spec) > 0,    'harness spec non-empty');
    ok(length($harn_a->events) > 0,  'harness events non-empty');
};

done_testing;
