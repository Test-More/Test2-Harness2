use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;

use Test2::Harness2::Util::JSON qw/encode_json/;
use App::Yath2::Log;

# Build a synthetic log directory with two jobs:
#   t/fast.t  -- started_at=100, ended_at=100.5 -> child_wall 0.5
#   t/slow.t  -- started_at=100, ended_at=220   -> child_wall 120
#
# speedtag.pm derives duration from spec.started_at and report.ended_at.
# We verify that the read path surfaces those two values correctly.

sub build_logdir {
    my $tmp = tempdir(CLEANUP => 1);

    # Job 1: fast.t (0.5 s)
    make_path("$tmp/runs/1/jobs/1/1");
    {
        open my $fh, '>', "$tmp/runs/1/jobs/1/1/spec.jsonl" or die $!;
        print $fh encode_json({
            test_file  => {absolute => '/abs/t/fast.t', relative => 't/fast.t'},
            queued_at  => 99,
            started_at => 100,
        }), "\n";
        close $fh;

        open $fh, '>', "$tmp/runs/1/jobs/1/1/report.jsonl" or die $!;
        print $fh encode_json({
            pass     => 1,
            ended_at => 100.5,
            exit     => 0,
        }), "\n";
        close $fh;
    }

    # Job 2: slow.t (120 s)
    make_path("$tmp/runs/1/jobs/2/1");
    {
        open my $fh, '>', "$tmp/runs/1/jobs/2/1/spec.jsonl" or die $!;
        print $fh encode_json({
            test_file  => {absolute => '/abs/t/slow.t', relative => 't/slow.t'},
            queued_at  => 99,
            started_at => 100,
        }), "\n";
        close $fh;

        open $fh, '>', "$tmp/runs/1/jobs/2/1/report.jsonl" or die $!;
        print $fh encode_json({
            pass     => 1,
            ended_at => 220,
            exit     => 0,
        }), "\n";
        close $fh;
    }

    return $tmp;
}

# Collect duration data via App::Yath2::Log, mirroring the read path
# that App::Yath2::Command::speedtag uses: last_try per job, then
# spec.started_at / report.ended_at to compute the wall time.
sub collect_durations {
    my ($dir) = @_;

    my $log = App::Yath2::Log->new(auto => $dir);
    my %durations;

    for my $rid ($log->runs) {
        for my $jid ($log->jobs($rid)) {
            my $try = $log->last_try($rid, $jid);
            next unless defined $try;

            my $arts   = $log->artifacts({run_id => $rid, job_id => $jid, job_try => $try});
            my $spec   = $arts->spec_iter->first  // {};
            my $report = $arts->report_iter->last // {};

            my $tf   = $spec->{test_file} // {};
            my $rel  = $tf->{relative} // $tf->{file};
            next unless defined $rel;

            my $start = $spec->{started_at};
            my $stop  = $report->{ended_at};
            next unless defined $start && defined $stop;

            $durations{$rel} = $stop - $start;
        }
    }

    return %durations;
}

subtest 'child_wall values are read back correctly' => sub {
    my $dir = build_logdir();
    my %dur = collect_durations($dir);

    ok(exists $dur{'t/fast.t'}, 'fast.t has a duration entry');
    ok(exists $dur{'t/slow.t'}, 'slow.t has a duration entry');

    # fast.t: 100.5 - 100 = 0.5
    is($dur{'t/fast.t'}, 0.5, 'fast.t duration is 0.5 s');

    # slow.t: 220 - 100 = 120
    is($dur{'t/slow.t'}, 120, 'slow.t duration is 120 s');
};

subtest 'duration bucketing matches speedtag thresholds' => sub {
    my $dir = build_logdir();
    my %dur = collect_durations($dir);

    my $max_short  = 15;
    my $max_medium = 30;

    my %bucket;
    for my $rel (keys %dur) {
        my $t = $dur{$rel};
        $bucket{$rel} =
            $t < $max_short  ? 'short'  :
            $t < $max_medium ? 'medium' :
                               'long';
    }

    is($bucket{'t/fast.t'}, 'short', 'fast.t is short (<15 s)');
    is($bucket{'t/slow.t'}, 'long',  'slow.t is long  (>30 s)');
};

subtest 'last_try returns the highest try number' => sub {
    my $dir = build_logdir();
    my $log = App::Yath2::Log->new(auto => $dir);

    # Both jobs have only one try (try 1).
    is($log->last_try(1, 1), 1, 'last_try for job 1 is 1');
    is($log->last_try(1, 2), 1, 'last_try for job 2 is 1');
};

done_testing;
