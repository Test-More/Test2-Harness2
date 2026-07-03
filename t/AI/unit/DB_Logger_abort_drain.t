use Test2::V0;

# Ticket #158: a watchdog-aborted run must finalize PROMPTLY, not after the full
# ~30s DRAIN_TIMEOUT.
#
# After the run is announced done (run_done) the DB logger keeps draining until
# _all_finalized_imported goes true, so it can catch trailing finalize transitions
# + their blobs. But a watchdog-aborted job's collector never sends its
# finalize/EOF (the abort tears it down -- #131), so its status is frozen below
# 'finalized' forever and _all_finalized_imported can NEVER go true for it. Before
# #158 the drain therefore burned the whole DRAIN_TIMEOUT (~30s) on every aborted
# '-L' run before the timeout escape fired. #158 short-circuits that wait
# (_drain_complete): once the only laggards are aborted jobs, the drain ends.
#
# This changes only the drain TIMING -- the run is still classified 'broken' (its
# aborted collector never finalized) and #131's abort fold still records the job
# as failed. This exercises the fix directly (real Runner::Monitor fed synthetic
# payloads via a stub subscriber, an ephemeral SQLite DB the logger bootstraps),
# mirroring DB_Logger_global_collectors.t / DB_Logger_abort_fold.t.
#
# Skipped cleanly when the opt-in DB / zstd deps are missing (R11).

use Time::HiRes qw/time/;
use File::Temp qw/tempdir/;

use App::Yath2::Util::UUID qw/gen_uuid/;

skip_all "DBD::SQLite not available"    unless eval { require DBD::SQLite;    1 };
skip_all "DBIx::QuickORM not available" unless eval { require DBIx::QuickORM; 1 };

use Test2::Collector::Util::Zstd qw/HAVE_ZSTD compress_blob/;
skip_all "Compress::Zstd not available" unless HAVE_ZSTD;

use Test2::Collector::Util::JSON ();
use Test2::Harness2::Runner::Monitor;
use App::Yath2::DB::Logger;

# ---- a stub subscriber whose ->monitor hands back the real Runner::Monitor ----
# State is pre-fed before run(), so poll() is a no-op; completion is announced via
# the real monitor's harness_run_end (run_done), and the socket never "closes" (so
# the poll loop takes the run_done/drain path, not the EOF shortcut).
{
    package t2h2::StubSubscriber;
    sub new      { my ($c, %a) = @_; bless {%a}, $c }
    sub monitor  { $_[0]->{monitor} }
    sub poll     { }
    sub closed   { 0 }
    sub run_done { 0 }
}

my $tmp_root = tempdir(CLEANUP => 1);
my $db_seq   = 0;

sub new_logger {
    my ($run_id) = @_;
    my $mon = Test2::Harness2::Runner::Monitor->new;
    my $db  = "$tmp_root/abort-drain-" . ($db_seq++) . ".sqlite";
    my $log = App::Yath2::DB::Logger->new(
        workdir    => $tmp_root,
        run_id     => $run_id,
        target     => $db,
        subscriber => t2h2::StubSubscriber->new(monitor => $mon),
    );
    return ($mon, $log, $db);
}

# A minimal but real events.jsonl.zst so a finalized test collector's blob import
# actually succeeds (sets ARTIFACTS_DONE).
sub write_events_file {
    my ($uuid) = @_;
    my $path = "$tmp_root/$uuid.jsonl.zst";
    open(my $fh, '>:raw', $path) or die "Could not write '$path': $!";
    print $fh compress_blob(
        Test2::Collector::Util::JSON::encode_json({facet_data => {info => [{tag => 'NOTE', details => 'evt'}]}}) . "\n"
    );
    close($fh);
    return $path;
}

my $PASS_FS = {pass => 1, exit => 0, assertion_count => 1, pass_count => 1, fail_count => 0, subtests => []};

# ---- synthetic wire payloads (see Runner::Monitor::_process) ------------------
sub dispatch {
    my ($mon, $job_id, $file, $run_id) = @_;
    $mon->feed({facet_data => {harness_runner_job => {job_id => $job_id, state => 'dispatched', file => $file, run_id => $run_id}}});
}

# The watchdog-aborted mutation (no 'file' key: the runner merge-keeps the
# dispatched file, so the jobs row survives -- matching the real abort).
sub abort {
    my ($mon, $job_id, $run_id) = @_;
    $mon->feed({facet_data => {harness_runner_job => {job_id => $job_id, state => 'aborted', run_id => $run_id}}});
}

# A run-scoped test collector that STARTS but never finalizes ('running').
sub start_collector {
    my ($mon, $uuid, $name, $try, $run_id) = @_;
    $mon->feed({
        facet_data => {
            harness_collector        => {uuid => $uuid, name => $name, events_file => "$tmp_root/$uuid.jsonl.zst", try => $try, run_uuid => $run_id},
            harness_state_transition => {state => 'starting'},
        },
    });
}

# A run-scoped test collector taken all the way to 'finalized' + importable.
sub finalize_test {
    my ($mon, $uuid, $name, $run_id) = @_;
    write_events_file($uuid);
    start_collector($mon, $uuid, $name, 1, $run_id);
    $mon->feed({facet_data => {harness_collector => {uuid => $uuid}, harness_final_state         => $PASS_FS}});
    $mon->feed({facet_data => {harness_collector => {uuid => $uuid}, harness_collector_finalized => 1}});
}

sub run_end {
    my ($mon, $run_id) = @_;
    $mon->feed({facet_data => {harness_run_end => {run_id => $run_id}}});
}

# --------------------------------------------------------------------------- #
subtest '_drain_complete short-circuits an unfinalized collector on an aborted job' => sub {
    my $run_id = gen_uuid();
    my ($mon, $log) = new_logger($run_id);

    my $ajob = uc(gen_uuid());
    dispatch($mon, $ajob, 'aborted.tx', $run_id);
    start_collector($mon, gen_uuid(), 'aborted.tx', 1, $run_id);    # 'running', never finalizes
    abort($mon, $ajob, $run_id);                                    # -> Monitor job state 'aborted'

    finalize_test($mon, gen_uuid(), 'ok.tx', $run_id);             # a normal finished collector

    $log->_sync;

    ok(!$log->_all_finalized_imported,
        "the aborted job's un-finalized collector still blocks _all_finalized_imported (status classification unchanged)");
    ok($log->_drain_complete,
        "_drain_complete short-circuits: the only laggard is an aborted job, no EOF is coming (#158)");
};

# --------------------------------------------------------------------------- #
subtest '_drain_complete does NOT short-circuit a live (non-aborted) collector' => sub {
    my $run_id = gen_uuid();
    my ($mon, $log) = new_logger($run_id);

    dispatch($mon, uc(gen_uuid()), 'busy.tx', $run_id);
    start_collector($mon, gen_uuid(), 'busy.tx', 1, $run_id);      # 'running', job NOT aborted

    finalize_test($mon, gen_uuid(), 'ok.tx', $run_id);

    $log->_sync;

    ok(!$log->_drain_complete,
        "a still-running non-aborted collector keeps blocking the drain (no over-skip)");
};

# --------------------------------------------------------------------------- #
subtest 'the full poll loop finalizes an aborted run promptly, not after DRAIN_TIMEOUT' => sub {
    my $run_id = gen_uuid();
    my ($mon, $log) = new_logger($run_id);

    # One job that finishes cleanly.
    my $pjob = uc(gen_uuid());
    dispatch($mon, $pjob, 'ok.tx', $run_id);
    finalize_test($mon, gen_uuid(), 'ok.tx', $run_id);

    # One job whose collector started but was watchdog-aborted (never finalizes).
    my $ajob = uc(gen_uuid());
    dispatch($mon, $ajob, 'aborted.tx', $run_id);
    start_collector($mon, gen_uuid(), 'aborted.tx', 1, $run_id);
    abort($mon, $ajob, $run_id);

    run_end($mon, $run_id);    # the runner announced the run complete

    my $start   = time;
    my $exit    = $log->run;   # drive the real _run poll loop
    my $elapsed = time - $start;

    ok(
        $elapsed < 5,
        "aborted run drained promptly, not the full DRAIN_TIMEOUT ("
            . App::Yath2::DB::Logger::DRAIN_TIMEOUT() . "s)",
    ) or diag("elapsed=${elapsed}s -- the aborted collector likely stalled the drain");

    # #158 changed only the TIMING: the run is still 'broken' (its aborted
    # collector never finalized) and #131's fold still recorded the abort.
    is($exit, 1, "logger exited non-zero (the run did not finish cleanly)");

    my ($run) = $log->con->handle('runs')->all;
    is($run->field('status'), 'broken', "run row finalized 'broken' (aborted == incomplete)");
    is($run->field('passed'), 1,        "the clean job counted passed");
    is($run->field('failed'), 1,        "the aborted job counted failed exactly once (#131 fold survives)");

    my %jobs = map { lc($_->field('job_uuid')) => $_ } $log->con->handle('jobs')->all;
    is($jobs{lc $ajob}->field('failed'), 1, "aborted job's row folded failed=1");
    is($jobs{lc $ajob}->field('passed'), 0, "aborted job's row passed=0");
    is($jobs{lc $pjob}->field('passed'), 1, "clean job's row passed=1");
};

done_testing;
