use Test2::V0;

# Ticket #131: watchdog-aborted jobs are folded into DB rows.
#
# An aborted job's collector may never finalize (dispatch to a dead stage,
# owner-drop, wind-down/truncate, or a pid hard-kill grace fallback), so the
# collector-driven _upsert_tries records no verdict. Without the fold the job's
# tries stay NULL, _finalize_run_row skips it (next unless @tries / resolved),
# and the run is logged 'complete' with the failure silently hidden.
#
# The fold ('aborted == failed'): job_tries.status='broken', result=0, counted in
# runs.failed via the EXISTING finalize loop (jobs.passed/failed derived from
# tries -- one fold invariant, one counting source, non-incremental recount).
#
# This drives App::Yath2::DB::Logger::_sync / _finalize_run_row directly against a
# real Runner::Monitor fed synthetic payloads, injected via a stub subscriber, and
# an ephemeral SQLite DB (the logger bootstraps the schema on first connect).
# Skipped cleanly when the opt-in DB deps are missing (R11).

use File::Temp qw/tempdir/;

use App::Yath2::Util::UUID qw/gen_uuid derive_uuid/;

skip_all "DBD::SQLite not available"    unless eval { require DBD::SQLite;    1 };
skip_all "DBIx::QuickORM not available" unless eval { require DBIx::QuickORM; 1 };

use Test2::Harness2::Runner::Monitor;
use App::Yath2::DB::Logger;

# ---- a stub subscriber whose ->monitor hands back the real Runner::Monitor ----
{
    package t2h2::StubSubscriber;
    sub new     { my ($c, %a) = @_; bless {%a}, $c }
    sub monitor { $_[0]->{monitor} }
}

my $tmp_root = tempdir(CLEANUP => 1);
my $db_seq   = 0;

# Build a (monitor, logger) pair over a fresh sqlite DB. run_id is lowercase so it
# equals what the logger stores + the job scoping compares against exactly.
sub new_logger {
    my ($run_id) = @_;
    my $mon = Test2::Harness2::Runner::Monitor->new;
    my $db  = "$tmp_root/abort-" . ($db_seq++) . ".sqlite";
    my $log = App::Yath2::DB::Logger->new(
        workdir    => $tmp_root,
        run_id     => $run_id,
        target     => $db,
        subscriber => t2h2::StubSubscriber->new(monitor => $mon),
    );
    return ($mon, $log, $db);
}

# ---- synthetic wire payloads (see Runner::Monitor::_process) -----------------
sub dispatch {
    my ($mon, $job_id, $file, $run_id) = @_;
    $mon->feed({facet_data => {harness_runner_job => {job_id => $job_id, state => 'dispatched', file => $file, run_id => $run_id}}});
}

sub abort {
    my ($mon, $job_id, $run_id) = @_;
    # No 'file' key: the runner merge-keeps the dispatched file (Monitor.pm merges
    # on `exists`), so the jobs row survives -- matching the real abort mutation.
    $mon->feed({facet_data => {harness_runner_job => {job_id => $job_id, state => 'aborted', run_id => $run_id}}});
}

sub start_collector {
    my ($mon, $uuid, $name, $try, $run_id) = @_;
    $mon->feed({
        facet_data => {
            harness_collector        => {uuid => $uuid, name => $name, events_file => "$tmp_root/$uuid.jsonl.zst", try => $try, run_uuid => $run_id},
            harness_state_transition => {state => 'starting'},
        },
    });
}

sub final_state {
    my ($mon, $uuid, $fs) = @_;
    $mon->feed({facet_data => {harness_collector => {uuid => $uuid}, harness_final_state => $fs}});
}

# Convenience: all job_tries rows for a lc(job_uuid).
sub tries_for {
    my ($log, $job_id) = @_;
    my $juuid = lc($job_id);
    return grep { lc($_->field('job_uuid')) eq $juuid } $log->con->handle('job_tries')->all;
}

my $PASS_FS = {pass => 1, exit => 0, assertion_count => 1, pass_count => 1, fail_count => 0, subtests => []};

# --------------------------------------------------------------------------- #
subtest 'no-collector abort synthesizes a broken/0 try (rule 3)' => sub {
    my $run_id = gen_uuid();
    my ($mon, $log) = new_logger($run_id);

    # Uppercase job id exercises the lc() normalization (QuickORM uuid-case gotcha).
    my $job_id = uc(gen_uuid());
    dispatch($mon, $job_id, 'no_collector.tx', $run_id);
    abort($mon, $job_id, $run_id);

    $log->_sync;

    my @tries = tries_for($log, $job_id);
    is(scalar(@tries), 1, "exactly one synthesized job_tries row");

    my $t = $tries[0];
    is($t->field('try_ord'), 1,        "synthesized try_ord is 1 (no rows existed)");
    is($t->field('status'),  'broken', "status folded to 'broken'");
    is($t->field('result'),  0,        "result folded to 0 (aborted == failed)");
    is(lc($t->field('job_try_uuid')), derive_uuid(lc($job_id), 1),
        "job_try_uuid = derive_uuid(lc(job_uuid), 1)");
};

# --------------------------------------------------------------------------- #
subtest 'partial-collector abort updates the in-flight NULL try (rule 2)' => sub {
    my $run_id = gen_uuid();
    my ($mon, $log) = new_logger($run_id);

    my $job_id = uc(gen_uuid());
    my $cuuid  = gen_uuid();
    dispatch($mon, $job_id, 'partial.tx', $run_id);
    start_collector($mon, $cuuid, 'partial.tx', 1, $run_id);    # try 1, NO final_state
    abort($mon, $job_id, $run_id);

    $log->_sync;

    my @tries = tries_for($log, $job_id);
    is(scalar(@tries), 1, "still exactly one row (the in-flight try was updated in place)");
    is($tries[0]->field('try_ord'), 1,        "same ordinal (1)");
    is($tries[0]->field('status'),  'broken', "in-flight try updated to broken");
    is($tries[0]->field('result'),  0,        "in-flight try updated to result 0");
};

# --------------------------------------------------------------------------- #
subtest 'idempotent: repeated _sync + _finalize do not double-count' => sub {
    my $run_id = gen_uuid();
    my ($mon, $log) = new_logger($run_id);

    my $job_id = uc(gen_uuid());
    dispatch($mon, $job_id, 'idem.tx', $run_id);
    abort($mon, $job_id, $run_id);

    $log->_sync         for 1 .. 3;
    $log->_finalize_run_row for 1 .. 2;

    my @tries = tries_for($log, $job_id);
    is(scalar(@tries), 1, "still one try row after 3x _sync + 2x _finalize");

    my ($run) = $log->con->handle('runs')->all;
    is($run->field('passed'),  0, "runs.passed stable (count-once)");
    is($run->field('failed'),  1, "runs.failed stable (count-once)");
    is($run->field('retried'), 0, "runs.retried stable");
};

# --------------------------------------------------------------------------- #
subtest 'late passing collector for the aborted try is re-clobbered to broken/0' => sub {
    my $run_id = gen_uuid();
    my ($mon, $log) = new_logger($run_id);

    my $job_id = uc(gen_uuid());
    dispatch($mon, $job_id, 'late.tx', $run_id);
    abort($mon, $job_id, $run_id);
    $log->_sync;    # fold synthesizes the broken/0 try (ord 1)

    # The aborted attempt's OWN collector connects late with a PASSING verdict for
    # the same ordinal (same derived uuid). _upsert_tries updates it to pass, then
    # the fold (which runs AFTER _upsert_tries) re-asserts broken/0 -- last writer.
    my $cuuid = gen_uuid();
    start_collector($mon, $cuuid, 'late.tx', 1, $run_id);
    final_state($mon, $cuuid, $PASS_FS);
    $log->_sync;

    my @tries = tries_for($log, $job_id);
    is(scalar(@tries), 1, "still one row (late collector derives the same job_try_uuid)");
    is($tries[0]->field('status'), 'broken', "re-clobbered to broken (fire-once abort is authoritative)");
    is($tries[0]->field('result'), 0,        "re-clobbered to result 0");
};

# --------------------------------------------------------------------------- #
subtest 'combined run: abort(a) + abort(b) + pass(c) => passed=1 failed=2' => sub {
    my $run_id = gen_uuid();
    my ($mon, $log) = new_logger($run_id);

    my $job_a = uc(gen_uuid());    # no-collector abort
    my $job_b = uc(gen_uuid());    # partial-collector abort
    my $job_c = uc(gen_uuid());    # control pass
    my $col_b = gen_uuid();
    my $col_c = gen_uuid();

    dispatch($mon, $job_a, 'aaa.tx', $run_id);
    abort($mon, $job_a, $run_id);

    dispatch($mon, $job_b, 'bbb.tx', $run_id);
    start_collector($mon, $col_b, 'bbb.tx', 1, $run_id);
    abort($mon, $job_b, $run_id);

    dispatch($mon, $job_c, 'ccc.tx', $run_id);
    start_collector($mon, $col_c, 'ccc.tx', 1, $run_id);
    final_state($mon, $col_c, $PASS_FS);

    $log->_sync;
    $log->_finalize_run_row;

    my ($run) = $log->con->handle('runs')->all;
    is($run->field('passed'), 1, "one job passed (c)");
    is($run->field('failed'), 2, "two jobs failed (a + b, the aborts)");
    is($run->field('status'), 'complete', "run status complete (no terminal error)");

    my %by_uuid = map { lc($_->field('job_uuid')) => $_ } $log->con->handle('jobs')->all;
    is($by_uuid{lc $job_a}->field('failed'), 1, "aborted job a folded failed=1");
    is($by_uuid{lc $job_a}->field('passed'), 0, "aborted job a passed=0");
    is($by_uuid{lc $job_b}->field('failed'), 1, "aborted job b folded failed=1");
    is($by_uuid{lc $job_c}->field('passed'), 1, "control job c passed=1");
    is($by_uuid{lc $job_c}->field('failed'), 0, "control job c failed=0");

    is(scalar(tries_for($log, $job_a)), 1, "job a: one try row");
    is(scalar(tries_for($log, $job_b)), 1, "job b: one try row");
    is((tries_for($log, $job_c))[0]->field('result'), 1, "control try result 1");
};

# --------------------------------------------------------------------------- #
subtest 'second logger over the same DB re-folds onto the same rows (rule 1)' => sub {
    my $run_id = gen_uuid();
    my ($mon, $log1, $db) = new_logger($run_id);

    my $job_id = uc(gen_uuid());
    dispatch($mon, $job_id, 'shared.tx', $run_id);
    abort($mon, $job_id, $run_id);
    $log1->_sync;

    is(scalar(tries_for($log1, $job_id)), 1, "logger1 folded exactly one broken try");

    # A fresh logger (empty +abort_folded) over the SAME DB + SAME mirror state.
    my $log2 = App::Yath2::DB::Logger->new(
        workdir    => $tmp_root,
        run_id     => $run_id,
        target     => $db,
        subscriber => t2h2::StubSubscriber->new(monitor => $mon),
    );
    $log2->_sync;

    my @tries = tries_for($log2, $job_id);
    is(scalar(@tries), 1, "no duplicate: the cold-cache recompute matched the existing broken row");
    is($tries[0]->field('status'), 'broken', "still broken");
    is($tries[0]->field('result'), 0,        "still result 0");
};

# --------------------------------------------------------------------------- #
subtest 'finalize with no subscriber slot returns cleanly (no fold attempted)' => sub {
    # The #132 failure-path shape: _finalize_run_row may be called with no
    # subscriber ever built. The if-guard must skip the fold, not crash / create one.
    my $db  = "$tmp_root/no-sub.sqlite";
    my $log = App::Yath2::DB::Logger->new(
        workdir => $tmp_root,
        run_id  => gen_uuid(),
        target  => $db,
    );
    $log->_ensure_run_row(undef);    # seed a real run row (RUN_ROW_SEEDED)

    my $ok = eval { $log->_finalize_run_row; 1 };
    my $err = $@;
    ok($ok, "_finalize_run_row lived with no subscriber") or diag($err);
    ok(!$log->terminal_error, "no terminal error recorded");
    is(scalar($log->con->handle('job_tries')->all), 0, "no tries fabricated without a subscriber");
};

done_testing;
