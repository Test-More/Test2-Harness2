use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;

# Verify the App::Yath2::Renderer::Driver synthesis pipeline turns
# on-disk run_mutation snapshots into the lifecycle facets the
# renderer chain expects (harness_run / harness_job_queued /
# harness_job_start / harness_job_end / harness_job_exit /
# harness_run_end). Drives the diff helpers directly without
# spawning a child process, so this stays fast.

use App::Yath2::Renderer::Driver;

my $rid = 0;

# Round 1: queued.
my $s1 = {
    run_id     => $rid,
    created_at => 100.0,
    pending    => [42],
    running    => [],
    done       => [],
    results    => {
        42 => {
            queued_at => 100.0,
            job_try   => 0,
            abs_file  => '/tmp/a.t',
            rel_file  => 't/a.t',
        },
    },
};

# Round 2: running.
my $s2 = {
    %$s1,
    pending => [],
    running => [42],
    results => {
        42 => {
            %{$s1->{results}{42}},
            started_at => 101.0,
        },
    },
};

# Round 3: done, pass.
my $s3 = {
    %$s2,
    pending => [],
    running => [],
    done    => [42],
    results => {
        42 => {
            %{$s2->{results}{42}},
            completed_at => 102.0,
            pass         => 1,
            exit         => 0,
            codes        => [0, 0],
        },
    },
};

my %states;
my %seen_start;
my %seen_end;
my @queue;

App::Yath2::Renderer::Driver->_apply_run_state($rid, $s1, \%states, \%seen_start, \%seen_end, \@queue);
my @round1 = splice @queue, 0;
ok(
    (grep { $_->{facet_data}{harness_run} } @round1),
    'first snapshot synthesizes harness_run',
);
ok(
    (grep { $_->{facet_data}{harness_job_queued} } @round1),
    'first snapshot synthesizes harness_job_queued',
);

App::Yath2::Renderer::Driver->_apply_run_state($rid, $s2, \%states, \%seen_start, \%seen_end, \@queue);
my @round2 = splice @queue, 0;
ok(
    (grep { $_->{facet_data}{harness_job_start} } @round2),
    'second snapshot synthesizes harness_job_start',
);
ok(
    !(grep { $_->{facet_data}{harness_run} } @round2),
    'second snapshot does NOT re-emit harness_run',
);

App::Yath2::Renderer::Driver->_apply_run_state($rid, $s3, \%states, \%seen_start, \%seen_end, \@queue);
my @round3 = splice @queue, 0;
my ($end) = grep { $_->{facet_data}{harness_job_end} } @round3;
ok($end, 'third snapshot synthesizes harness_job_end');
is($end->{facet_data}{harness_job_end}{fail}, 0, 'job pass means fail=0');
is($end->{facet_data}{harness_job_end}{exit}, 0, 'job exit preserved');

ok(
    (grep { $_->{facet_data}{harness_job_exit} } @round3),
    'third snapshot synthesizes harness_job_exit',
);

my ($run_end) = grep { $_->{facet_data}{harness_run_end} } @round3;
ok($run_end, 'third snapshot synthesizes harness_run_end');
is($run_end->{facet_data}{harness_run_end}{pass}, 1, 'run pass=1 when no fails');
is($run_end->{facet_data}{harness_run_end}{pass_count}, 1, 'pass_count=1');
is($run_end->{facet_data}{harness_run_end}{fail_count}, 0, 'fail_count=0');

# Failing case: a snapshot whose only completed job has pass=0.
my $f = {
    run_id     => 1,
    created_at => 200.0,
    pending    => [],
    running    => [],
    done       => [9],
    results    => {
        9 => {
            queued_at    => 200.0,
            started_at   => 201.0,
            completed_at => 202.0,
            pass         => 0,
            exit         => 256,
            abs_file     => '/tmp/b.t',
            rel_file     => 't/b.t',
        },
    },
};
my %fs;
my %fss;
my %fse;
my @fq;
App::Yath2::Renderer::Driver->_apply_run_state(1, $f, \%fs, \%fss, \%fse, \@fq);
my ($fend) = grep { $_->{facet_data}{harness_job_end} } @fq;
is($fend->{facet_data}{harness_job_end}{fail}, 1, 'failing job synthesizes fail=1');
my ($frend) = grep { $_->{facet_data}{harness_run_end} } @fq;
is($frend->{facet_data}{harness_run_end}{pass}, 0, 'run pass=0 when any job fails');
is($frend->{facet_data}{harness_run_end}{fail_count}, 1, 'fail_count=1');

done_testing;
