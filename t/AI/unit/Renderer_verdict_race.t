use Test2::V0;
use feature 'signatures';
no warnings 'experimental::signatures';
use File::Temp qw/tempdir/;
use Time::HiRes qw/time sleep/;

use Test2::Collector::Event;
use Test2::Collector::Recorder::Zstd;

use Test2::Harness2::Runner::Monitor;
use Test2::Harness2::Renderer::Driver;

# Regression for the completed-before-final-state verdict race (review P1):
#
# The driver renders a job's completion off the Monitor's `completed` transition
# (new_completed). Per the JobReader ordering, the `completed` transition arrives
# BEFORE the separate, later harness_final_state record (and the events file's
# terminal). Before the fix, _render_completion's feed_events_file bailed on the
# first empty poll (`last unless @events`) when the events file had not yet
# flushed its terminal records, fell back to synth_job_end with an undef
# final_state -- which means fail=1 -- and marked the uuid `ended` so the real
# final state could never correct it. A PASSING job rendered FAILED.
#
# This test drives the race deterministically: it feeds the driver a `completed`
# transition for a collector whose events file does NOT yet contain the terminal,
# then a background writer appends the (passing) terminal a moment later. The
# fixed driver bounded-waits for the terminal and settles the TRUE verdict.

{
    package StubSink;
    sub new          { bless {events => []}, shift }
    sub render_event { push @{$_[0]{events}} => $_[1]; return }
    sub step         { }
    sub finish       { }
    sub events       { @{$_[0]{events}} }
}

my $ev = sub { bless({facet_data => {@_}}, 'Test2::Collector::Event') };

my $dir  = tempdir(CLEANUP => 1);
my $file = "$dir/pass-events.jsonl.zst";

# Write only the PRE-terminal portion of a PASSING job's events file: an
# assertion, but NOT the harness_process_exit / harness_final_state terminal yet.
# This is exactly the state the file is in when the `completed` transition fires
# but the later final-state record has not been flushed.
my $rec = Test2::Collector::Recorder::Zstd->new(file => $file);
$rec->record_event($ev->(assert => {pass => 1, number => 1, details => 'a'}));
# do NOT finalize: leave the file open/short of its terminal.

# Drive a Monitor with one PASSING test collector, then a `completed` transition
# with NO folded harness_final_state -- the exact ordering the bug rode on.
my $mon  = Test2::Harness2::Runner::Monitor->new;
my $uuid = 'UUID-PASS';
$mon->feed({facet_data => {harness_collector => {uuid => $uuid, name => 't/pass.t', events_file => $file, run_uuid => 'RUN-1', try => 0}, harness_state_transition => {state => 'starting'}}});
$mon->feed({facet_data => {harness_collector => {uuid => $uuid}, harness_state_transition => {state => 'completed'}}});

ok(!$mon->collector($uuid)->{final_state}, "final_state NOT folded yet (completed arrived first)");

my $sink = StubSink->new;
my $settings = mock {} => (add => [check_group => sub { 0 }]);

my $driver = Test2::Harness2::Renderer::Driver->new(
    settings  => $settings,
    renderers => [$sink],
    run_id    => 'RUN-1',
    tasks     => [{job_id => 'JOB-PASS', file => 't/pass.t', rel_file => 't/pass.t'}],
);

# Background writer: after a short delay, append the PASSING terminal records and
# finalize the file. This lands AFTER the driver has already started rendering
# completion, so the driver must bounded-wait for it rather than settle off the
# transient EOF.
my $pid = fork // die "fork: $!";
unless ($pid) {
    sleep 0.15;
    $rec->record_event($ev->(harness_process_exit => {all => 0, err => 0, sig => 0, dmp => 0, stamp => 1}));
    $rec->record_event($ev->(harness_final_state => {pass => 1, fail_count => 0, pass_count => 1, assertion_count => 1, exit => 0}));
    $rec->finalize;
    exit 0;
}

my $start = time;
$driver->step($mon);
waitpid($pid, 0);

# The driver must have waited for the terminal (it appeared ~0.15s in), proving
# it did not settle off the transient EOF.
ok((time - $start) >= 0.1, "driver bounded-waited for the events-file terminal");

# The held/dispatched harness_job_end must reflect the TRUE (passing) verdict.
my ($end) = grep { $_->facet_data->{harness_job_end} } $sink->events;
ok($end, "a harness_job_end was rendered");
is($end->facet_data->{harness_job_end}{fail}, 0, "PASSING job rendered with fail=0 (NOT prematurely FAILED)");

# And the run-level rollup must agree: pass, nothing failed, nothing unseen.
$driver->finalize($mon);
my $final = $driver->final_data;
is($final->{pass}, 1, "run rollup PASSED");
ok(!$final->{failed}, "no failed jobs in rollup");
ok(!$final->{unseen}, "no unseen jobs in rollup");

done_testing;
