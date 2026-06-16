use Test2::V0;
use feature 'signatures';
no warnings 'experimental::signatures';
use File::Temp qw/tempdir/;

use Test2::Collector::Event;
use Test2::Collector::Recorder::Zstd;

use Test2::Harness2::Runner::Monitor;
use Test2::Harness2::Renderer::Base;

# This exercises the REUSABLE base-renderer mechanics (§4.5) in isolation from
# the interim per-job 3-phase ordering that lives in Renderer::Driver:
#   * locate a collector's events.jsonl.zst from transition state (Monitor)
#   * read it BY PATH and fan its recorded events out to a render_event sink
#   * compute the run-level harness_final rollup from per-job verdicts
#
# A minimal stub sink captures every event the base dispatches, standing in for
# the real Formatter / DB / Server sinks (which are unchanged render_event
# consumers).

{
    package StubSink;
    sub new   { bless {events => []}, shift }
    sub render_event { push @{$_[0]{events}} => $_[1]; return }
    sub step  { }
    sub events { @{$_[0]{events}} }
}

# Write a complete collector events file the way Test2-Collector would.
my $ev = sub { bless({facet_data => {@_}}, 'Test2::Collector::Event') };

sub write_events_file {
    my ($file, $pass) = @_;
    my $rec = Test2::Collector::Recorder::Zstd->new(file => $file);
    $rec->record_event($ev->(assert => {pass => $pass, number => 1, details => 'a'}));
    $rec->record_event($ev->(harness_process_exit => {all => $pass ? 0 : 256, err => $pass ? 0 : 1, sig => 0, dmp => 0, stamp => 1}));
    $rec->record_event($ev->(harness_final_state => {pass => $pass, fail_count => $pass ? 0 : 1, pass_count => $pass ? 1 : 0, assertion_count => 1, exit => $pass ? 0 : 256}));
    $rec->finalize;
    return;
}

my $dir   = tempdir(CLEANUP => 1);
my $pfile = "$dir/pass-events.jsonl.zst";
my $ffile = "$dir/fail-events.jsonl.zst";
write_events_file($pfile, 1);
write_events_file($ffile, 0);

# Drive a real Monitor with two test collectors via the transition wire form,
# each carrying its events_file path -- exactly what rides on a 'starting'
# transition (see Test2::Collector / Runner::Monitor).
my $mon = Test2::Harness2::Runner::Monitor->new;

my %starts = (
    'UUID-PASS' => {name => 't/pass.t', events_file => $pfile, run_uuid => 'RUN-1', try => 0},
    'UUID-FAIL' => {name => 't/fail.t', events_file => $ffile, run_uuid => 'RUN-1', try => 0},
);

for my $uuid (sort keys %starts) {
    my $hc = {uuid => $uuid, %{$starts{$uuid}}};
    $mon->feed({facet_data => {harness_collector => $hc, harness_state_transition => {state => 'starting'}}});
    $mon->feed({facet_data => {harness_collector => {uuid => $uuid}, harness_final_state => {pass => ($uuid eq 'UUID-PASS' ? 1 : 0)}}});
    $mon->feed({facet_data => {harness_collector => {uuid => $uuid}, harness_state_transition => {state => 'completed'}}});
}

# Build a Base directly (no Driver subclass): we are testing the base mechanics.
my $sink = StubSink->new;

my $settings = mock {} => (add => [
    check_group => sub { 0 },
]);

my $base = Test2::Harness2::Renderer::Base->new(
    settings  => $settings,
    renderers => [$sink],
    run_id    => 'RUN-1',
    tasks     => [
        {job_id => 'JOB-PASS', file => 't/pass.t', rel_file => 't/pass.t'},
        {job_id => 'JOB-FAIL', file => 't/fail.t', rel_file => 't/fail.t'},
    ],
);

subtest locate_and_read => sub {
    # The base locates each collector's events file from transition state and
    # reads it BY PATH, fanning every recorded event out to the sink.
    for my $uuid (sort $mon->tests) {
        my $c = $mon->collector($uuid);
        ok($c->{events_file}, "monitor tracks events_file for $uuid");

        my $job = $base->job_for($c);
        my @held = $base->feed_events_file(
            $c->{events_file},
            job_id  => $job->{job_id},
            job_try => 0,
            file    => $c->{name},
            hold    => sub ($e) { $e->{facet_data}{harness_job_end} ? 1 : 0 },
        );

        # The held event is the synthesized job_end; record the verdict from it.
        $base->note_verdict($job, 0, $held[0]->{facet_data}{harness_job_end}) if @held;
    }

    my %facets;
    for my $e ($sink->events) {
        $facets{$_}++ for keys %{$e->facet_data};
    }

    ok($facets{assert},          "assert events fanned out to the sink");
    ok($facets{harness_job_exit}, "synthesized harness_job_exit fanned out");
    ok(!$facets{harness_job_end}, "harness_job_end was HELD (not dispatched by the base)");
};

subtest compute_final => sub {
    my $final = $base->compute_final;

    is($final->{pass}, 0, "run failed (one job failed)");
    is($final->{failed}, [['JOB-FAIL', 't/fail.t']], "the failing job is listed");
    ok(!$final->{unseen}, "no unseen jobs (both produced verdicts)");
    is($base->final_data, $final, "final_data accessor returns the rollup");
};

subtest empty_path_is_noop => sub {
    my @held = $base->feed_events_file(undef, job_id => 'X');
    is(\@held, [], "feed_events_file is a no-op for an empty path");
};

done_testing;
