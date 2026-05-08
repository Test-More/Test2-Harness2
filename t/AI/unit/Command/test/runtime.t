use Test2::V0;

# Verify the App::Yath2::Renderer::Driver synthesis pipeline turns
# the run service's skinny transition events (run_queued / run_started
# / job_started / job_completed / run_completed) plus per-job
# spec/report artifacts into the lifecycle facets the renderer chain
# expects (harness_run / harness_job_queued / harness_job_start /
# harness_job_end / harness_job_exit / harness_run_end). Drives
# _maybe_synthesize_lifecycle directly with a fake Log so we don't
# spawn a child process.

use App::Yath2::Renderer::Driver;
use Test2::Harness2::Event;

# Fake log: artifacts(rid, jid, try) returns a stub artifact whose
# spec_iter / report_iter return canned rows.
{

    package FakeArtifact;
    sub new { my ($c, %h) = @_; bless {%h}, $c }
    sub spec_iter   { FakeIter->new(rows => [$_[0]->{spec}   // {}]) }
    sub report_iter { FakeIter->new(rows => [$_[0]->{report} // {}]) }

    package FakeIter;
    sub new {
        my ($c, %h) = @_;
        bless {rows => $h{rows} // [], i => 0}, $c;
    }

    sub next {
        my $self = shift;
        return undef if $self->{i} >= @{$self->{rows}};
        return $self->{rows}[$self->{i}++];
    }

    package FakeLog;
    sub new { my ($c, %h) = @_; bless {%h}, $c }

    sub artifacts {
        my ($self, $rid, $jid, $try) = @_;
        $try //= 0;
        my $key = "$rid/$jid/$try";
        return $self->{jobs}{$key} // FakeArtifact->new;
    }
}

sub mk_event {
    my ($facets) = @_;
    return Test2::Harness2::Event->new(facet_data => $facets);
}

my $rid = 0;
my $log = FakeLog->new(
    jobs => {
        "0/0/0" => FakeArtifact->new(
            spec => {
                absolute   => '/tmp/a.t',
                relative   => 't/a.t',
                queued_at  => 100,
                started_at => 101,
            },
            report => {
                pass => 1, exit => 0, exit_decoded => {sig => 0, err => 0},
                ended_at => 102, times => [0, 0, 0.1, 0],
                child_times => [0, 0, 0.1, 0], child_wall => 1.0,
            },
        ),
        "1/9/0" => FakeArtifact->new(
            spec   => {absolute => '/tmp/b.t', relative => 't/b.t', queued_at => 200},
            report => {
                pass => 0, exit => 256, exit_decoded => {err => 1, all => 256, dmp => 0, sig => 0},
                ended_at => 202, times => [0, 0, 0.2, 0],
                child_times => [0, 0, 0.2, 0], child_wall => 1.0,
            },
        ),
    },
);

my %states;
my %seen_start;
my %seen_end;
my @queue;

my $synth = sub {
    my ($event) = @_;
    App::Yath2::Renderer::Driver->_maybe_synthesize_lifecycle(
        $event, $log, \%states, \%seen_start, \%seen_end, \@queue,
    );
};

# Round 1: run_queued -> harness_run + harness_job_queued
$synth->(mk_event({
    harness => {
        run_id     => $rid,
        kind       => 'run_queued',
        queued_at  => 100,
        total_jobs => 1,
        job_ids    => [0],
    },
}));

ok((grep { $_->{facet_data}{harness_run} } @queue),
    'run_queued synthesizes harness_run');
my ($q) = grep { $_->{facet_data}{harness_job_queued} } @queue;
ok($q, 'run_queued synthesizes harness_job_queued');
is($q->{facet_data}{harness_job_queued}{rel_file}, 't/a.t',
    'harness_job_queued rel_file fetched from spec artifact');
is($q->{facet_data}{harness_job_queued}{abs_file}, '/tmp/a.t',
    'harness_job_queued abs_file fetched from spec artifact');
is($q->{facet_data}{harness_job_queued}{stamp}, 100,
    'harness_job_queued stamp from spec.queued_at');
@queue = ();

# Round 2: run_started -- no synthesized event, just stash started_at.
$synth->(mk_event({
    harness => {run_id => $rid, kind => 'run_started', started_at => 101},
}));
is($states{$rid}{started_at}, 101, 'run_started stashes started_at');
is(scalar(@queue), 0, 'run_started does not synthesize a lifecycle facet');

# Round 3: job_started -> harness_job_start
$synth->(mk_event({
    harness => {
        run_id   => $rid,
        kind     => 'job_started',
        stamp    => 101,
        job_info => {run_id => $rid, job_id => 0, job_try => 0},
    },
}));

my ($s) = grep { $_->{facet_data}{harness_job_start} } @queue;
ok($s, 'job_started synthesizes harness_job_start');
is($s->{facet_data}{harness_job_start}{rel_file}, 't/a.t',
    'harness_job_start rel_file from spec');
is($s->{facet_data}{harness_job_start}{stamp}, 101,
    'harness_job_start stamp from event');
@queue = ();

# Round 4: job_completed -> harness_job_end + harness_job_exit
$synth->(mk_event({
    harness => {
        run_id   => $rid,
        kind     => 'job_completed',
        stamp    => 102,
        pass     => 1,
        job_info => {run_id => $rid, job_id => 0, job_try => 0},
    },
}));

my ($end) = grep { $_->{facet_data}{harness_job_end} } @queue;
ok($end, 'job_completed synthesizes harness_job_end');
is($end->{facet_data}{harness_job_end}{fail}, 0, 'pass means fail=0');
is($end->{facet_data}{harness_job_end}{exit}, 0, 'exit fetched from report');
is($end->{facet_data}{harness_job_end}{rel_file}, 't/a.t', 'rel_file from spec');
is($end->{facet_data}{harness_job_end}{times}, [0, 0, 0.1, 0],
    'times fetched from report');

ok((grep { $_->{facet_data}{harness_job_exit} } @queue),
    'job_completed synthesizes harness_job_exit');
@queue = ();

# Round 5: run_completed -> harness_run_end
$synth->(mk_event({
    harness => {
        run_id         => $rid,
        run_completed  => {run_id => $rid, stamp => 103},
    },
    collector_report => {
        pass         => 1,
        passed_jobs  => 1,
        failed_jobs  => 0,
        started_at   => 100,
        ended_at     => 103,
    },
}));

my ($run_end) = grep { $_->{facet_data}{harness_run_end} } @queue;
ok($run_end, 'run_completed synthesizes harness_run_end');
is($run_end->{facet_data}{harness_run_end}{pass}, 1, 'run pass=1');
is($run_end->{facet_data}{harness_run_end}{pass_count}, 1, 'pass_count=1');
is($run_end->{facet_data}{harness_run_end}{fail_count}, 0, 'fail_count=0');
is($run_end->{facet_data}{harness_run_end}{wall_time}, 3, 'wall_time = ended_at - started_at');
ok(defined $run_end->{facet_data}{harness_run_end}{cumulative_job_time},
    'cumulative_job_time aggregated from cached per-job report');

# Failing case: separate run with one failing job.
{
    my %fs;
    my %fss;
    my %fse;
    my @fq;
    my $synth_f = sub {
        App::Yath2::Renderer::Driver->_maybe_synthesize_lifecycle(
            $_[0], $log, \%fs, \%fss, \%fse, \@fq,
        );
    };

    $synth_f->(mk_event({
        harness => {
            run_id   => 1, kind => 'run_queued',
            queued_at => 200, total_jobs => 1, job_ids => [9],
        },
    }));
    $synth_f->(mk_event({
        harness => {
            run_id   => 1, kind => 'job_completed',
            stamp    => 202, pass => 0,
            job_info => {run_id => 1, job_id => 9, job_try => 0},
        },
    }));

    my ($fend) = grep { $_->{facet_data}{harness_job_end} } @fq;
    is($fend->{facet_data}{harness_job_end}{fail}, 1,
        'failing job synthesizes fail=1');
    is($fend->{facet_data}{harness_job_end}{exit}, 256,
        'exit pulled from report artifact');
}

done_testing;
