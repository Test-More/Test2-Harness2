use Test2::V0;

# Ticket #132: the DB logger must NOT finalize a run as 'complete' (exit 0) when
# the runner died mid-run or the drain timed out with blobs still unimported.
#
# runs.status is what CI gating / dashboards key on, so a killed-mid-run or
# partially-imported run being logged 'complete' with exit 0 silently lies. A run
# is 'complete' (exit 0) ONLY when the runner ANNOUNCED the run end (run_done) AND
# every one of this run's collectors finalized + imported its events blob.
# Otherwise the run is 'broken' and the logger exits non-zero:
#   * runner died / was force-killed before run_done  -> socket EOF before run_done;
#   * the drain timed out with a collector still unfinalized (blob unimported);
#   * a collector's events blob failed to import (corrupt / unreadable).
#
# Drives App::Yath2::DB::Logger's real run() poll loop against a real
# Runner::Monitor fed synthetic payloads, via a stub subscriber (whose closed /
# run_done are configurable) and an ephemeral SQLite DB. Skipped cleanly when the
# opt-in DB / zstd deps are missing (spec R11).

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
# State is pre-fed before run(), so poll() is a no-op; `closed` and `run_done` are
# configurable so a subtest can model a transient-runner EOF (closed) with or
# without an announced run end.
{
    package t2h2::StubSubscriber;
    sub new      { my ($c, %a) = @_; bless {closed => 0, run_done => 0, %a}, $c }
    sub monitor  { $_[0]->{monitor} }
    sub poll     { }
    sub closed   { $_[0]->{closed} }
    sub run_done { $_[0]->{run_done} }
}

# A logger subclass with an instant drain timeout, so the drain-timeout subtest
# does not have to wait the real 30s DRAIN_TIMEOUT for the loop to give up.
{
    package t2h2::FastDrainLogger;
    our @ISA = ('App::Yath2::DB::Logger');
    sub DRAIN_TIMEOUT { 0 }
}

my $tmp_root = tempdir(CLEANUP => 1);
my $db_seq   = 0;

sub new_logger {
    my (%args) = @_;
    my $class  = delete($args{class}) // 'App::Yath2::DB::Logger';
    my $run_id = delete($args{run_id});
    my $mon    = Test2::Harness2::Runner::Monitor->new;
    my $db     = "$tmp_root/finalize-" . ($db_seq++) . ".sqlite";
    my $log    = $class->new(
        workdir    => $tmp_root,
        run_id     => $run_id,
        target     => $db,
        subscriber => t2h2::StubSubscriber->new(monitor => $mon, %args),
    );
    return ($mon, $log, $db);
}

# A minimal but real events.jsonl.zst (one self-contained zstd frame) so a
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

# A CORRUPT events.jsonl.zst (>=6 bytes, bad zstd magic) so the import fails
# deterministically -- exactly the "corrupt one events blob" case.
sub write_corrupt_events_file {
    my ($uuid) = @_;
    my $path = "$tmp_root/$uuid.jsonl.zst";
    open(my $fh, '>:raw', $path) or die "Could not write '$path': $!";
    print $fh "NOT-A-ZSTD-FRAME\x00\x01\x02\x03\x04\x05";
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
    my ($mon, $uuid, $name, $try, $run_id) = @_;
    $mon->feed({
        facet_data => {
            harness_collector        => {uuid => $uuid, name => $name, events_file => "$tmp_root/$uuid.jsonl.zst", try => $try, run_uuid => $run_id},
            harness_state_transition => {state => 'starting'},
        },
    });
}

# Finalize a test collector with a real (importable) blob.
sub finalize_test {
    my ($mon, $uuid, $name, $run_id) = @_;
    write_events_file($uuid);
    start_collector($mon, $uuid, $name, 1, $run_id);
    $mon->feed({facet_data => {harness_collector => {uuid => $uuid}, harness_final_state         => $PASS_FS}});
    $mon->feed({facet_data => {harness_collector => {uuid => $uuid}, harness_collector_finalized => 1}});
}

# Finalize a test collector whose on-disk blob is CORRUPT (import will fail).
sub finalize_test_corrupt {
    my ($mon, $uuid, $name, $run_id) = @_;
    write_corrupt_events_file($uuid);
    start_collector($mon, $uuid, $name, 1, $run_id);
    $mon->feed({facet_data => {harness_collector => {uuid => $uuid}, harness_final_state         => $PASS_FS}});
    $mon->feed({facet_data => {harness_collector => {uuid => $uuid}, harness_collector_finalized => 1}});
}

sub run_end {
    my ($mon, $run_id) = @_;
    $mon->feed({facet_data => {harness_run_end => {run_id => $run_id}}});
}

sub run_row_status {
    my ($log) = @_;
    my ($run) = $log->con->handle('runs')->all;
    return $run ? $run->field('status') : undef;
}

# --------------------------------------------------------------------------- #
# CONTROL: a clean run (run_done announced + all collectors finalized+imported)
# still finalizes 'complete' and exits 0 -- the happy path must not regress.
subtest 'clean run finalizes complete + exit 0 (control)' => sub {
    my $run_id = gen_uuid();
    my ($mon, $log) = new_logger(run_id => $run_id, run_done => 1);

    dispatch($mon, uc(gen_uuid()), 'ok.tx', $run_id);
    finalize_test($mon, gen_uuid(), 'ok.tx', $run_id);
    run_end($mon, $run_id);    # runner announced the run end

    my $exit = $log->run;

    is($exit, 0, "clean run exits 0");
    is(run_row_status($log), 'complete', "clean run finalized 'complete'");
    ok(!$log->terminal_error, "no terminal error on a clean run");
    is(scalar(@{$log->errors}), 0, "no errors recorded on a clean run");
};

# --------------------------------------------------------------------------- #
# The runner died / was force-killed mid-run: the socket closes (EOF) but the run
# end was NEVER announced. Even though the collector we DID see imported fine, the
# run is 'broken' and the logger exits non-zero -- not 'complete'/0.
subtest 'runner died mid-run (EOF before run_done) => broken + non-zero exit' => sub {
    my $run_id = gen_uuid();
    my ($mon, $log) = new_logger(run_id => $run_id, closed => 1, run_done => 0);

    dispatch($mon, uc(gen_uuid()), 'ok.tx', $run_id);
    finalize_test($mon, gen_uuid(), 'ok.tx', $run_id);    # imports fine -- not the cause
    # NO run_end fed: the runner crashed before announcing the run's completion.

    my $exit = $log->run;

    ok($exit, "logger exits non-zero when the runner died mid-run") or diag("exit=$exit");
    is(run_row_status($log), 'broken', "run finalized 'broken', not 'complete'");
    ok(!$log->terminal_error, "no *terminal* error -- broken came from the missing run_done, not a crash-detect");
    is(scalar(@{$log->errors}), 0, "no import errors -- the collector we saw imported cleanly");
};

# --------------------------------------------------------------------------- #
# The run end WAS announced, but a run-scoped collector never finalized, so the
# drain times out with its blob unimported. The run is 'broken' + non-zero, and
# the loop gives up promptly (not the real 30s DRAIN_TIMEOUT).
subtest 'drain timeout with an unimported blob => broken + non-zero exit' => sub {
    my $run_id = gen_uuid();
    my ($mon, $log) = new_logger(class => 't2h2::FastDrainLogger', run_id => $run_id, run_done => 1);

    dispatch($mon, uc(gen_uuid()), 'done.tx', $run_id);
    finalize_test($mon, gen_uuid(), 'done.tx', $run_id);          # this one finalized + imported
    start_collector($mon, gen_uuid(), 'busy.tx', 1, $run_id);     # run-scoped, NEVER finalizes
    run_end($mon, $run_id);

    my $start = time;
    my $exit  = $log->run;
    my $elapsed = time - $start;

    ok($exit, "logger exits non-zero on a drain timeout with an unimported blob") or diag("exit=$exit");
    is(run_row_status($log), 'broken', "run finalized 'broken', not 'complete'");
    ok($elapsed < 5, "drain gave up promptly (${elapsed}s), it did not stall")
        or diag("elapsed=${elapsed}s");
    ok(!$log->terminal_error, "no terminal error -- broken came from the drain-timeout classification");
};

# --------------------------------------------------------------------------- #
# A collector's events blob is corrupt: the import fails and is recorded. The run
# is 'broken' + non-zero, and the warning names the offending collector.
subtest 'corrupt events blob => broken + non-zero exit, warning names the collector' => sub {
    my $run_id = gen_uuid();
    my ($mon, $log) = new_logger(run_id => $run_id, run_done => 1);

    my $bad_uuid = gen_uuid();
    dispatch($mon, uc(gen_uuid()), 'corrupt.tx', $run_id);
    finalize_test_corrupt($mon, $bad_uuid, 'corrupt.tx', $run_id);
    run_end($mon, $run_id);

    my @warnings;
    my $exit;
    {
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        $exit = $log->run;
    }

    ok($exit, "logger exits non-zero when a collector blob failed to import") or diag("exit=$exit");
    is(run_row_status($log), 'broken', "run finalized 'broken', not 'complete'");
    ok(scalar(@{$log->errors}), "an import error was recorded");
    like(
        join('', @warnings),
        qr/\Q$bad_uuid\E/,
        "the recorded warning names the offending collector uuid",
    );
    like(join('', @warnings), qr/Failed to import collector/, "warning describes the import failure");
};

done_testing;
