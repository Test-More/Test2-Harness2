use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;

use Test2::Harness2::Util::JSON qw/encode_json/;
use App::Yath2::Log;

# Build a synthetic log directory with a single run containing two jobs:
# job 1 passes, job 2 fails. Each job has try 1.
#
# Per the new_log_refactor layout:
#   runs/<rid>/jobs/<jid>/<try>/spec.jsonl    -- test_file, queued_at
#   runs/<rid>/jobs/<jid>/<try>/report.jsonl  -- pass, ended_at, exit

sub build_logdir {
    my $tmp = tempdir(CLEANUP => 1);

    # Run 1, Job 1, Try 1 -> passing
    make_path("$tmp/runs/1/jobs/1/1");
    {
        open my $fh, '>', "$tmp/runs/1/jobs/1/1/spec.jsonl" or die $!;
        print $fh encode_json({
            test_file  => {absolute => '/abs/passing.t', relative => 't/passing.t'},
            queued_at  => 1000,
            started_at => 1001,
        }), "\n";
        close $fh;

        open $fh, '>', "$tmp/runs/1/jobs/1/1/report.jsonl" or die $!;
        print $fh encode_json({
            pass     => 1,
            ended_at => 1005,
            exit     => 0,
        }), "\n";
        close $fh;
    }

    # Run 1, Job 2, Try 1 -> failing
    make_path("$tmp/runs/1/jobs/2/1");
    {
        open my $fh, '>', "$tmp/runs/1/jobs/2/1/spec.jsonl" or die $!;
        print $fh encode_json({
            test_file  => {absolute => '/abs/failing.t', relative => 't/failing.t'},
            queued_at  => 1000,
            started_at => 1001,
        }), "\n";
        close $fh;

        open $fh, '>', "$tmp/runs/1/jobs/2/1/report.jsonl" or die $!;
        print $fh encode_json({
            pass     => 0,
            ended_at => 1010,
            exit     => 1,
        }), "\n";
        close $fh;
    }

    return $tmp;
}

# Walk runs -> jobs -> tries via App::Yath2::Log, collect pass/fail per
# relative file path. This exercises the same read path that
# App::Yath2::Command::failed uses internally.
sub collect_results {
    my ($dir) = @_;

    my $log = App::Yath2::Log->new(auto => $dir);

    my %by_file;
    for my $rid ($log->runs) {
        for my $jid ($log->jobs($rid)) {
            for my $try ($log->tries($rid, $jid)) {
                my $arts = $log->artifacts({run_id => $rid, job_id => $jid, job_try => $try});

                my $spec   = $arts->spec_iter->first   // {};
                my $report = $arts->report_iter->last  // {};

                my $tf  = $spec->{test_file} // {};
                my $rel = $tf->{relative} // $tf->{file};
                next unless defined $rel;

                $by_file{$rel} = {
                    pass     => $report->{pass} ? 1 : 0,
                    ended_at => $report->{ended_at},
                };
            }
        }
    }
    return %by_file;
}

subtest 'failing job is detected, passing job is not' => sub {
    my $dir = build_logdir();
    my %results = collect_results($dir);

    ok(exists $results{'t/failing.t'}, 'failing.t is in results');
    ok(exists $results{'t/passing.t'}, 'passing.t is in results');

    is($results{'t/failing.t'}{pass}, 0, 'failing.t has pass=0');
    is($results{'t/passing.t'}{pass}, 1, 'passing.t has pass=1');

    my @failed = grep { !$results{$_}{pass} } sort keys %results;
    is(\@failed, ['t/failing.t'], 'exactly one failing file: t/failing.t');
};

subtest 'log->runs and log->jobs return expected ids' => sub {
    my $dir = build_logdir();
    my $log = App::Yath2::Log->new(auto => $dir);

    my @runs = $log->runs;
    is(\@runs, [1], 'one run with id 1');

    my @jobs = $log->jobs(1);
    is(\@jobs, [1, 2], 'two jobs in run 1, sorted ascending');

    my @tries_j1 = $log->tries(1, 1);
    is(\@tries_j1, [1], 'job 1 has exactly one try');
};

subtest 'spec_iter and report_iter decode fields correctly' => sub {
    my $dir = build_logdir();
    my $log = App::Yath2::Log->new(auto => $dir);

    # Use the failing job (job 2, try 1) to verify field decoding.
    my $arts   = $log->artifacts({run_id => 1, job_id => 2, job_try => 1});
    my $spec   = $arts->spec_iter->first  // {};
    my $report = $arts->report_iter->last // {};

    my $tf = $spec->{test_file} // {};
    is($tf->{relative}, 't/failing.t', 'spec relative path is t/failing.t');
    is($tf->{absolute}, '/abs/failing.t', 'spec absolute path is /abs/failing.t');

    is($report->{pass},     0,    'report pass=0 for failing job');
    is($report->{exit},     1,    'report exit=1 for failing job');
    is($report->{ended_at}, 1010, 'report ended_at decoded correctly');
};

done_testing;
