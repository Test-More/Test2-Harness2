use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;

use Test2::Harness2::Util::JSON  qw/encode_json/;
use Test2::Harness2::Util::Zstd  qw/open_zstd_writer/;
use App::Yath2::Log;

# Build a synthetic on-disk layout:
#
#   services/harness/events.jsonl.zst (carries collector_start for run 0,
#                                      then collector_end for run 0)
#   runs/0/events.jsonl.zst           (carries collector_start for job 0/0
#                                      then collector_end for job 0/0)
#   runs/0/jobs/0/0/events.jsonl.zst  (carries one plain event)

my $dir = tempdir(CLEANUP => 1);
make_path("$dir/services/harness");
make_path("$dir/runs/0");
make_path("$dir/runs/0/jobs/0/0");

sub write_jsonl_zst {
    my ($path, @rows) = @_;
    my $w = open_zstd_writer($path);
    for my $row (@rows) {
        $w->say(encode_json($row));
    }
    $w->close;
}

write_jsonl_zst(
    "$dir/services/harness/events.jsonl.zst",
    {facet_data => {harness => {note => 'harness up'}}},
    {facet_data => {harness_collector_start => {
        type => 'Run',
        id   => 0,
        run_id => 0,
        collector_pid => 1001,
        collected_pid => 1002,
        started_at    => 1.0,
    }}},
    {facet_data => {harness_collector_end => {
        type => 'Run',
        id   => 0,
        run_id => 0,
        collector_pid => 1001,
        collected_pid => 1002,
        ended_at => 2.0,
        exit => 0,
    }}},
    {facet_data => {harness => {note => 'harness shutting down'}}},
);

write_jsonl_zst(
    "$dir/runs/0/events.jsonl.zst",
    {facet_data => {harness => {note => 'run started'}}},
    {facet_data => {harness_collector_start => {
        type   => 'Job',
        id     => 0,
        run_id => 0,
        job_try => 0,
        collector_pid => 2001,
        collected_pid => 2002,
        started_at    => 1.5,
    }}},
    {facet_data => {harness_collector_end => {
        type   => 'Job',
        id     => 0,
        run_id => 0,
        job_try => 0,
        collector_pid => 2001,
        collected_pid => 2002,
        ended_at => 1.8,
        exit => 0,
    }}},
    {facet_data => {harness => {note => 'run done'}}},
);

write_jsonl_zst(
    "$dir/runs/0/jobs/0/0/events.jsonl.zst",
    {facet_data => {assert => {pass => 1, details => 'first'}}},
    {facet_data => {assert => {pass => 1, details => 'second'}}},
);

my $log = App::Yath2::Log->new(dir => $dir);

# Drive the iterator and collect everything.
my @collected;
while (my $e = $log->event(0)) {
    push @collected => $e;
    last if @collected > 100;
}

ok($log->EOE, 'EOE flips true after stack drains');

my @notes;
my @asserts;
my @starts;
my @ends;
for my $e (@collected) {
    my $fd = $e->{facet_data};
    push @notes,   $fd->{harness}{note}      if $fd->{harness} && $fd->{harness}{note};
    push @asserts, $fd->{assert}{details}    if $fd->{assert};
    push @starts,  $fd->{harness_collector_start} if $fd->{harness_collector_start};
    push @ends,    $fd->{harness_collector_end}   if $fd->{harness_collector_end};
}

# Depth-first: a 'collector_start' is followed by the child collector's
# events before we resume the parent.
is(\@notes, ['harness up', 'run started', 'run done', 'harness shutting down'],
    'depth-first notes order');

is(\@asserts, ['first', 'second'], 'job events surfaced between run start and end');

is(scalar(@starts), 2, 'two collector_start events');
is(scalar(@ends),   2, 'two collector_end events');

# Path-aware identifier injection: the assert events must carry
# run_id, job_id, job_try in facet_data.harness.
my @assert_events = grep { $_->{facet_data}{assert} } @collected;
is(scalar(@assert_events), 2, 'two assert events');
for my $e (@assert_events) {
    is($e->{facet_data}{harness}{run_id},  0, 'run_id injected');
    is($e->{facet_data}{harness}{job_id},  0, 'job_id injected');
    is($e->{facet_data}{harness}{job_try}, 0, 'job_try injected');
}

# Reset re-runs from the top.
$log->reset;
my $first = $log->event(0);
is($first->{facet_data}{harness}{note}, 'harness up', 'reset rewinds');

done_testing;
