use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;

use Test2::Harness2::Util::JSON qw/encode_json/;
use App::Yath2::Log;

# Build a synthetic log directory with one job whose spec and report
# carry all the timing fields that App::Yath2::Command::times consumes:
#
#   spec.jsonl    -- started_at
#   report.jsonl  -- ended_at  (total = ended_at - started_at)

sub build_logdir {
    my $tmp = tempdir(CLEANUP => 1);

    # Run 1, three jobs with distinct total durations.
    for my $spec (
        [1, 'quick',  100, 101],   # 1 s
        [2, 'middle', 100, 105],   # 5 s
        [3, 'slow',   100, 110],   # 10 s
    ) {
        my ($jid, $name, $start, $stop) = @$spec;
        make_path("$tmp/runs/1/jobs/$jid/1");

        open my $fh, '>', "$tmp/runs/1/jobs/$jid/1/spec.jsonl" or die $!;
        print $fh encode_json({
            test_file  => {relative => "t/$name.t", absolute => "/abs/t/$name.t"},
            queued_at  => 99,
            started_at => $start,
        }), "\n";
        close $fh;

        open $fh, '>', "$tmp/runs/1/jobs/$jid/1/report.jsonl" or die $!;
        print $fh encode_json({
            pass     => 1,
            ended_at => $stop,
            exit     => 0,
        }), "\n";
        close $fh;
    }

    return $tmp;
}

# Walk the log the same way App::Yath2::Command::times does: last_try
# per job, then read spec.started_at / report.ended_at, compute total.
sub collect_times {
    my ($dir) = @_;

    my $log = App::Yath2::Log->new(auto => $dir);
    my @jobs;

    for my $rid ($log->runs) {
        for my $jid ($log->jobs($rid)) {
            my $try = $log->last_try($rid, $jid);
            next unless defined $try;

            my $arts   = $log->artifacts({run_id => $rid, job_id => $jid, job_try => $try});
            my $spec   = $arts->spec_iter->first  // {};
            my $report = $arts->report_iter->last // {};

            my $tf   = $spec->{test_file} // {};
            my $file = $tf->{relative} // $tf->{file} // $tf->{absolute};
            next unless defined $file;

            my $start = $spec->{started_at};
            my $stop  = $report->{ended_at};
            next unless defined $start && defined $stop;

            push @jobs => {file => $file, total => $stop - $start};
        }
    }

    return @jobs;
}

subtest 'all timing fields are present and correct' => sub {
    my $dir = build_logdir();
    my @jobs = collect_times($dir);

    is(scalar @jobs, 3, 'three jobs returned');

    my %by_file = map { $_->{file} => $_ } @jobs;

    ok(exists $by_file{'t/quick.t'},  'quick.t in results');
    ok(exists $by_file{'t/middle.t'}, 'middle.t in results');
    ok(exists $by_file{'t/slow.t'},   'slow.t in results');

    is($by_file{'t/quick.t'}{total},  1,  'quick.t  total = 1  s');
    is($by_file{'t/middle.t'}{total}, 5,  'middle.t total = 5  s');
    is($by_file{'t/slow.t'}{total},   10, 'slow.t   total = 10 s');
};

subtest 'jobs sort shortest to longest by default (numeric total)' => sub {
    my $dir  = build_logdir();
    my @jobs = sort { $a->{total} <=> $b->{total} } collect_times($dir);

    is(
        [map { $_->{file} } @jobs],
        ['t/quick.t', 't/middle.t', 't/slow.t'],
        'ascending sort by total matches expected order',
    );
};

subtest 'total duration is correct for each job' => sub {
    my $dir = build_logdir();
    my $log = App::Yath2::Log->new(auto => $dir);

    # Directly check job 3 (slow.t: 10 s) via artifacts API.
    my $arts   = $log->artifacts({run_id => 1, job_id => 3, job_try => 1});
    my $spec   = $arts->spec_iter->first  // {};
    my $report = $arts->report_iter->last // {};

    is($spec->{started_at},   100, 'spec started_at = 100');
    is($report->{ended_at},   110, 'report ended_at = 110');
    is($report->{ended_at} - $spec->{started_at}, 10, 'total = 10 s');
};

done_testing;
