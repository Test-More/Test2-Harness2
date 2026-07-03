use Test2::V0;

# Ticket #130: the DB logger must NOT wait on global/service collectors.
#
# A persistent runner serves a single runner.socket for every run; besides a
# run's own test collectors it also owns GLOBAL/service collectors -- the runner's
# own sampler collector (unconditional) and the preload-stage roots (when preloads
# are configured). Those ride the monitor's shared global bucket into every
# run-scoped subscriber's mirror, carry an UNDEF run_uuid, and NEVER finalize. The
# old _all_finalized_imported required *every* collector the mirror knew about to
# be finalized+imported, so it could never return true while a daemon collector sat
# at 'running' -- and the drain loop polled the full 30s DRAIN_TIMEOUT after every
# single '-L' run before giving up. This exercises the fix (#130): the per-run
# fold + drain checks skip collectors whose run_uuid != RUN_ID.
#
# Drives App::Yath2::DB::Logger's _sync / _all_finalized_imported / run directly
# against a real Runner::Monitor fed synthetic payloads, via a stub subscriber and
# an ephemeral SQLite DB (the logger bootstraps the schema on first connect).
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
# the real monitor's harness_run_end (run_done), and the socket never "closes".
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
    my $db  = "$tmp_root/global-" . ($db_seq++) . ".sqlite";
    my $log = App::Yath2::DB::Logger->new(
        workdir    => $tmp_root,
        run_id     => $run_id,
        target     => $db,
        subscriber => t2h2::StubSubscriber->new(monitor => $mon),
    );
    return ($mon, $log, $db);
}

# A minimal but real events.jsonl.zst (one self-contained zstd frame) so the
# finalized test collector's blob import actually succeeds (sets ARTIFACTS_DONE).
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

sub start_collector {
    my ($mon, $uuid, $name, $try, $run_id) = @_;    # try defined => 'test', undef => 'service'
    $mon->feed({
        facet_data => {
            harness_collector        => {uuid => $uuid, name => $name, events_file => "$tmp_root/$uuid.jsonl.zst", try => $try, run_uuid => $run_id},
            harness_state_transition => {state => 'starting'},
        },
    });
}

sub finalize_test {
    my ($mon, $uuid, $name, $run_id) = @_;
    write_events_file($uuid);                       # real blob for the import
    start_collector($mon, $uuid, $name, 1, $run_id);
    $mon->feed({facet_data => {harness_collector => {uuid => $uuid}, harness_final_state          => $PASS_FS}});
    $mon->feed({facet_data => {harness_collector => {uuid => $uuid}, harness_collector_finalized  => 1}});
}

# A GLOBAL/service collector: NO try (=> 'service'), NO run_uuid (=> global
# bucket), and it NEVER finalizes -- exactly the runner's sampler / preload roots.
sub start_global_service {
    my ($mon, $uuid, $name) = @_;
    $mon->feed({
        facet_data => {
            harness_collector        => {uuid => $uuid, name => $name, events_file => "$tmp_root/$uuid.jsonl.zst"},
            harness_state_transition => {state => 'starting'},
        },
    });
}

sub run_end {
    my ($mon, $run_id) = @_;
    $mon->feed({facet_data => {harness_run_end => {run_id => $run_id}}});
}

# --------------------------------------------------------------------------- #
subtest 'a running global service collector does not block _all_finalized_imported' => sub {
    my $run_id = gen_uuid();
    my ($mon, $log) = new_logger($run_id);

    dispatch($mon, uc(gen_uuid()), 'ok.tx', $run_id);
    finalize_test($mon, gen_uuid(), 'ok.tx', $run_id);    # run-scoped, finalized
    start_global_service($mon, gen_uuid(), 'harness');    # daemon collector, still 'running'

    $log->_sync;    # imports the finalized run-scoped collector -> ARTIFACTS_DONE

    ok($log->_all_finalized_imported,
        "drain ends early: the never-finalizing global service collector is ignored (#130)");
};

# --------------------------------------------------------------------------- #
subtest 'an unfinalized RUN-SCOPED collector still blocks the drain (fix did not over-skip)' => sub {
    my $run_id = gen_uuid();
    my ($mon, $log) = new_logger($run_id);

    dispatch($mon, uc(gen_uuid()), 'done.tx', $run_id);
    finalize_test($mon, gen_uuid(), 'done.tx', $run_id);          # finalized run-scoped
    start_collector($mon, gen_uuid(), 'busy.tx', 1, $run_id);     # run-scoped, NOT finalized

    $log->_sync;

    ok(!$log->_all_finalized_imported,
        "an unfinalized RUN-scoped collector still blocks the drain (run-scoped collectors are still checked)");
};

# --------------------------------------------------------------------------- #
subtest '_upsert_collectors attributes only this run\'s collectors' => sub {
    my $run_id = gen_uuid();
    my $other  = gen_uuid();    # a different run
    my ($mon, $log) = new_logger($run_id);

    my $ctest   = gen_uuid();
    my $cglobal = gen_uuid();
    my $cother  = gen_uuid();

    dispatch($mon, uc(gen_uuid()), 'ok.tx', $run_id);
    finalize_test($mon, $ctest, 'ok.tx', $run_id);               # run-scoped
    start_global_service($mon, $cglobal, 'harness');             # global (run_uuid undef)
    start_collector($mon, $cother, 'foreign.tx', 1, $other);     # foreign run (run_uuid ne RUN_ID)

    $log->_sync;

    my %rows = map { lc($_->field('collector_uuid')) => $_ } $log->con->handle('collectors')->all;
    ok($rows{lc $ctest},    "run-scoped collector row present");
    ok(!$rows{lc $cglobal}, "global service collector NOT misattributed to this run");
    ok(!$rows{lc $cother},  "foreign-run collector NOT attributed to this run");
    is(scalar(keys %rows), 1, "exactly one collectors row (only this run's)");
};

# --------------------------------------------------------------------------- #
subtest 'the full poll loop finalizes promptly, not after DRAIN_TIMEOUT' => sub {
    my $run_id = gen_uuid();
    my ($mon, $log) = new_logger($run_id);

    dispatch($mon, uc(gen_uuid()), 'ok.tx', $run_id);
    finalize_test($mon, gen_uuid(), 'ok.tx', $run_id);      # run-scoped, finalized + importable
    start_global_service($mon, gen_uuid(), 'harness');      # daemon collector, never finalizes
    run_end($mon, $run_id);                                 # runner announced the run complete

    my $start   = time;
    my $exit    = $log->run;                                # drive the real _run poll loop
    my $elapsed = time - $start;

    is($exit, 0, "logger exited cleanly (no terminal error)");
    ok(
        $elapsed < 5,
        "drain ended promptly, not the full DRAIN_TIMEOUT ("
            . App::Yath2::DB::Logger::DRAIN_TIMEOUT() . "s)",
    ) or diag("elapsed=${elapsed}s -- the global collector likely stalled the drain");

    my ($run) = $log->con->handle('runs')->all;
    is($run->field('status'), 'complete', "run row finalized 'complete'");
};

done_testing;
