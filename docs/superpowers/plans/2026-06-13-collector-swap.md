# Collector Swap (Chunk 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run each test under a Test2-Collector collector that emits one `events.jsonl.zst` (events + transitions) per job; have the yath gatherer tail those files; delete this repo's in-tree auditor, parsers, JobDir, and Test2 stream formatter, plus the auditor process.

**Architecture:** The runner's per-job child becomes a Test2-Collector collector parent (`Test2::Collector::collect`, `run_sub` for the preload/fork path, `exec` otherwise) whose recorder writes `events.jsonl.zst`. The gatherer (`Test2::Harness2::Collector`) replaces `JobDir`'s file-scrape+TAP-parse with a `JobReader` that tails the zstd file, wraps each record as a `Test2::Harness2::Event` with job identity, and synthesizes the harness facets the renderer expects. Run-level pass/fail aggregation moves into the gatherer (replacing the deleted auditor process).

**Tech Stack:** Perl 5.38+, Test2-Collector (loaded via `t2clib` symlink), Object::HashBase, prove, zstd (`Test2::Collector::Util::Zstd`).

**Worktree:** `worktrees/collector-swap` (branch `collector-swap`, off `2.0d`). The `t2clib` symlink already exists there → `/home/exodist/projects/Test2/Test2-Collector/lib`.

**Test command (mandatory `-Ilib`, and `-It2clib` where `Test2::Collector*` is loaded):** `prove -Ilib -It2clib -j16 -r t/`

---

## Key reference facts (verified from both repos)

**Test2-Collector `collect(%args)`** (`t2clib/Test2/Collector.pm`) — relevant args:
`name` (req), `is_test` (bool), `run_uuid` (req when is_test), one of `exec`/`run` (alias for `run_sub`), `recorder` (instance), `record_transitions` (NEW — added in Task 1), `silence_timeout` (test only, 0=off), `lifetime_timeout` (test only), `orphan_timeout` (default 30), `io_events` (bool; undef = formatter default on), `child_env`/`env` (hashref), `chdir`, `stdin`, `try` (test only). Returns an info hash `{exit => {sig,err,dmp,all,...}, final_state => {...}?, collector => {ok,errors}}`.

**Recorder:** `Test2::Collector::Recorder::Zstd->new(file => $path)` (compressed by default, one self-contained zstd frame per event, `autoflush(1)`). Path accessor: `$recorder->file`.

**Recorded record shape:** each frame decodes (after zstd) to a JSON object `{ "facet_data" => { ... } }` (Event::TO_JSON returns `{%$self}` and the Event holds only `facet_data`).

**Reading a growing file:** `Test2::Collector::Util::Zstd::open_zstd_reader($path)` → reader; `$reader->readline` returns the next decompressed JSON string or `undef` when no complete new frame is available yet (safe to call repeatedly while the file grows; `$reader->truncated` is true when a partial frame is pending).

**Facet name map (Test2-Collector → what the harness renderer/consumers read):**
- `harness_process_exit` `{sig,err,dmp,all,stamp,times?,memory?,timed_out?,orphaned?}` → harness needs `harness_job_exit` `{exit,code,signal,dumped,retry,job_id,job_try,stamp,...}`.
- `harness_final_state` `{pass,fail_count,pass_count,assertion_count,exit,subtests,plan?,halt?,times?,stamp}` → harness needs `harness_job_end` `{file,rel_file,abs_file,retry,fail,stamp,times?}` and feeds the run rollup.
- `harness_state_transition` `{state,stamp}` (states: starting/failing/diagnosing/completed/exited), `harness_collector_finalized` `{stamp}` — passed through (used by chunk 5; harmless now).
- `from_tap` / `from_stream` `{source,details}`, `assert`, `plan`, `control`, `trace`, `info`, `parent` (Assembler nests subtests into `parent.children`), `amnesty` — standard / shared.
- `harness` subtest markers: Test2-Collector uses `harness.{subtest_start,subtest_started,subtest_end,subtest_closed}`; the 1.0 renderer used `harness.{subtest_start,subtest_end}`.

**Current pipeline being torn out:** runner injects `-MTest2::Formatter::Stream=dir,$event_dir,job_id,$job_id` (`Runner/Job.pm` `cli_options` ~466) + writes `stdout`/`stderr`/`exit`/`event_timeout`/`post_exit_timeout` files; gatherer's `JobDir` scrapes them + parses TAP; the separate auditor process (`start_auditor`, `Command/auditor.pm`, `Auditor`+`Watcher`) validates and emits `harness_job_end`/`harness_final`.

---

## Task 1: Test2-Collector — record transitions into the recorder

**Repo:** `/home/exodist/projects/Test2/Test2-Collector` (separate dist; its own commit).
**Files:**
- Modify: `lib/Test2/Collector.pm` (HashBase block ~45-83; `init` ~109-180; `_route_event` ~575-588)
- Test: `t/` — add `t/record_transitions.t`

- [ ] **Step 1.1: Write the failing test.** Create `/home/exodist/projects/Test2/Test2-Collector/t/record_transitions.t`:

```perl
use Test2::V0;
use Test2::Collector;
use Test2::Collector::Recorder::JSONL;
use File::Temp qw/tempdir/;
use Test2::Collector::Util::JSON qw/decode_json/;

my $dir = tempdir(CLEANUP => 1);
my $file = "$dir/events.jsonl";

# A passing test job, recorder only (no reporter), record_transitions on.
my $info = Test2::Collector::collect(
    name               => 't/fake',
    is_test            => 1,
    run_uuid           => 'RUN-1',
    record_transitions => 1,
    recorder           => Test2::Collector::Recorder::JSONL->new(file => $file),
    run                => sub {
        print "1..1\n";
        print "ok 1 - pass\n";
    },
);

ok($info->{collector}{ok}, "collector ok") or diag explain $info->{collector};

open(my $fh, '<', $file) or die "open $file: $!";
my @recs = map { decode_json($_) } <$fh>;
close($fh);

my @transitions = grep { $_->{facet_data}{harness_state_transition} } @recs;
my @finals      = grep { $_->{facet_data}{harness_final_state} } @recs;
my @asserts     = grep { $_->{facet_data}{assert} } @recs;

ok(@asserts,     "regular events recorded");
ok(@transitions, "state transitions recorded into the events file");
ok(@finals,      "final_state recorded into the events file");

done_testing;
```

- [ ] **Step 1.2: Run it, verify it fails.** Run: `cd /home/exodist/projects/Test2/Test2-Collector && perl -Ilib t/record_transitions.t`
  Expected: FAIL — `@transitions`/`@finals` empty (transitions currently go only to a reporter, and there is none).

- [ ] **Step 1.3: Add the attribute.** In `lib/Test2/Collector.pm` HashBase block (the `use Object::HashBase qw{ ... }` at ~45-83), add a line near `<reporter`:

```perl
    <record_transitions
```

- [ ] **Step 1.4: Default it in `init`.** In `init` (~109-180), alongside the other `//=` arg defaults, add:

```perl
    # When no reporter is configured, transitions have nowhere to go; record
    # them into the events file so a recorder-only collector produces one
    # complete stream (events + transitions + final state). An explicit
    # record_transitions value always wins.
    $self->{+RECORD_TRANSITIONS} //= $self->{+REPORTER} ? 0 : 1;
```

- [ ] **Step 1.5: Branch in `_route_event`.** Replace the body of `_route_event` (~575-588) with:

```perl
sub _route_event ($self, $event) {
    my $f = $event->facet_data;

    if ($f->{harness_state_transition} || $f->{harness_final_state} || $f->{harness_collector_finalized}) {
        $self->_report($event) if $self->{+REPORTER};

        # Also (or instead) write the transition to the recorder so the events
        # file is self-contained. _report() may stamp harness_collector onto the
        # facet_data; that is fine to persist.
        if ($self->{+RECORD_TRANSITIONS} && (my $recorder = $self->{+RECORDER})) {
            unless (eval { $recorder->record_event($event); 1 }) {
                $self->_collector_failure("recorder record_event failed (transition): $@");
                $self->_abort_run($recorder);
            }
        }

        return;
    }

    my $recorder = $self->{+RECORDER} or return;
    unless (eval { $recorder->record_event($event); 1 }) {
        $self->_collector_failure("recorder record_event failed: $@");
        $self->_abort_run($recorder);
    }

    return;
}
```

- [ ] **Step 1.6: Run the test, verify it passes.** Run: `perl -Ilib t/record_transitions.t` → PASS. Then the dist's own suite: `prove -Ilib -j8 t/ 2>&1 | tail -5` → no regressions.

- [ ] **Step 1.7: Commit (in the Test2-Collector repo).**

```bash
cd /home/exodist/projects/Test2/Test2-Collector
git add lib/Test2/Collector.pm t/record_transitions.t
git commit -m "feat: record_transitions option to write transitions into the events file

When enabled (default on when no reporter is configured), state-transition,
final-state, and finalized events are written to the recorder in addition to
(or instead of) the reporter, so a recorder-only collector produces one
self-contained events file containing the full stream plus transitions.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 1.8: Note for the harness side.** From here, harness `collect()` calls pass `record_transitions => 1` (explicit) and no reporter. Return to the harness worktree for all remaining tasks: `cd /home/exodist/projects/Test2/Test2-Harness/worktrees/collector-swap`.

---

## Task 2: `JobReader` — tail one `events.jsonl.zst` into harness events

This is the gatherer's new per-job reader, replacing `JobDir`. TDD it against a hand-built fixture so it is provable without a live runner.

**Files:**
- Create: `lib/Test2/Harness2/Collector/JobReader.pm`
- Test: `t/unit/Test2/Harness2/Collector/JobReader.t`

- [ ] **Step 2.1: Write the failing test.** Create `t/unit/Test2/Harness2/Collector/JobReader.t`:

```perl
use Test2::V0;
use lib 't2clib';
use File::Temp qw/tempdir/;
use Test2::Collector::Recorder::Zstd;

use Test2::Harness2::Collector::JobReader;

my $dir  = tempdir(CLEANUP => 1);
my $file = "$dir/events.jsonl.zst";

# Build a fixture events file the way Test2-Collector would: one frame per
# event, each a {facet_data => {...}} record.
my $rec = Test2::Collector::Recorder::Zstd->new(file => $file);
my $ev = sub { my %fd = @_; bless({facet_data => {@_}}, 'Test2::Collector::Event') };
$rec->record_event($ev->(from_tap => {source => 'STDOUT', details => '1..1'}, plan => {count => 1}));
$rec->record_event($ev->(assert => {pass => 1, number => 1, details => 'pass'}));
$rec->record_event($ev->(harness_final_state => {pass => 1, fail_count => 0, pass_count => 1, assertion_count => 1, exit => 0}));
$rec->record_event($ev->(harness_process_exit => {err => 0, sig => 0, dmp => 0, all => 0, stamp => 123}));
$rec->finalize;

my $reader = Test2::Harness2::Collector::JobReader->new(
    job_id     => 'JOB-1',
    job_try    => 0,
    run_id     => 'RUN-1',
    events_file => $file,
    file        => "t/foo.t",
);

my @events;
# Poll until done (the fixture is complete, so a couple of polls suffice).
for (1 .. 5) {
    push @events => $reader->poll(1000);
    last if $reader->done;
}

ok($reader->done, "reader saw process exit and drained");

# Every emitted event is a harness event carrying job identity.
ok($_->isa('Test2::Harness2::Event'), "wrapped as harness event") for @events;
is($events[0]->job_id, 'JOB-1', "job_id attached");

my %seen = map { my $fd = $_->facet_data; map {($_ => 1)} keys %$fd } @events;
ok($seen{assert},           "assert passed through");
ok($seen{from_tap},         "from_tap passed through");
ok($seen{harness_job_exit}, "synthesized harness_job_exit from harness_process_exit");
ok($seen{harness_job_end},  "synthesized harness_job_end from harness_final_state");

my ($exit_ev) = grep { $_->facet_data->{harness_job_exit} } @events;
is($exit_ev->facet_data->{harness_job_exit}{exit}, 0,        "exit code mapped");
is($exit_ev->facet_data->{harness_job_exit}{job_id}, 'JOB-1', "exit carries job_id");

my ($end_ev) = grep { $_->facet_data->{harness_job_end} } @events;
is($end_ev->facet_data->{harness_job_end}{fail}, 0,        "job_end fail derived from final_state");
is($end_ev->facet_data->{harness_job_end}{file}, "t/foo.t", "job_end carries file");

done_testing;
```

- [ ] **Step 2.2: Run it, verify it fails.** Run: `perl -Ilib -It2clib t/unit/Test2/Harness2/Collector/JobReader.t`
  Expected: FAIL — `Can't locate Test2/Harness2/Collector/JobReader.pm`.

- [ ] **Step 2.3: Implement `JobReader`.** Create `lib/Test2/Harness2/Collector/JobReader.pm`:

```perl
package Test2::Harness2::Collector::JobReader;
use strict;
use warnings;

our $VERSION = '2.000000';

use File::Spec();
use Test2::Collector::Util::Zstd qw/open_zstd_reader/;
use Test2::Collector::Util::JSON qw/decode_json/;
use Test2::Harness2::Util::UUID qw/gen_uuid/;
use Test2::Harness2::Event;

use Test2::Harness2::Util::HashBase qw{
    <job_id <job_try <run_id <file <events_file
    +reader +done +last_stamp +final_state
};

sub init {
    my $self = shift;
    die "job_id is required"      unless defined $self->{+JOB_ID};
    die "events_file is required" unless defined $self->{+EVENTS_FILE};
    $self->{+JOB_TRY} //= 0;
}

sub done { $_[0]->{+DONE} }

sub reader {
    my $self = shift;
    return $self->{+READER} if $self->{+READER};
    return undef unless -e $self->{+EVENTS_FILE};
    return $self->{+READER} = open_zstd_reader($self->{+EVENTS_FILE});
}

# Return up to $max wrapped harness events; empty list if nothing new yet.
sub poll {
    my $self = shift;
    my ($max) = @_;

    return () if $self->{+DONE};

    my $reader = $self->reader or return ();

    my @out;
    while (!defined($max) || @out < $max) {
        my $line = $reader->readline;
        last unless defined $line;

        my $rec = decode_json($line);
        my $fd  = $rec->{facet_data} or next;

        push @out => $self->_wrap($fd);

        # Synthesize harness facets the renderer/rollup expect.
        if (my $fs = $fd->{harness_final_state}) {
            $self->{+FINAL_STATE} = $fs;
            push @out => $self->_wrap({harness_job_end => $self->_job_end_facet($fs)});
        }

        if (my $px = $fd->{harness_process_exit}) {
            push @out => $self->_wrap({harness_job_exit => $self->_job_exit_facet($px)});
            $self->{+DONE} = {retry => 0};
        }
    }

    return @out;
}

sub _wrap {
    my $self = shift;
    my ($fd) = @_;

    my $stamp = $self->_stamp_for($fd);

    return Test2::Harness2::Event->new(
        event_id   => gen_uuid(),
        job_id     => $self->{+JOB_ID},
        job_try    => $self->{+JOB_TRY},
        run_id     => $self->{+RUN_ID},
        stamp      => $stamp,
        facet_data => $fd,
    );
}

sub _stamp_for {
    my $self = shift;
    my ($fd) = @_;
    for my $f (qw/harness_process_exit harness_final_state harness_state_transition/) {
        return $self->{+LAST_STAMP} = $fd->{$f}{stamp} if $fd->{$f} && defined $fd->{$f}{stamp};
    }
    return $self->{+LAST_STAMP} = $fd->{trace}{stamp} if $fd->{trace} && defined $fd->{trace}{stamp};
    return $self->{+LAST_STAMP};
}

sub _job_exit_facet {
    my $self = shift;
    my ($px) = @_;
    return {
        details => "Test script exited " . ($px->{all} // 0),
        exit    => $px->{all} // 0,
        code    => $px->{err} // 0,
        signal  => $px->{sig} // 0,
        dumped  => $px->{dmp} // 0,
        retry   => 0,
        job_id  => $self->{+JOB_ID},
        job_try => $self->{+JOB_TRY},
        stamp   => $px->{stamp},
        times   => $px->{times},
    };
}

sub _job_end_facet {
    my $self = shift;
    my ($fs) = @_;
    my $file = $self->{+FILE};
    return {
        file     => $file,
        rel_file => defined($file) ? File::Spec->abs2rel($file) : undef,
        abs_file => defined($file) ? File::Spec->rel2abs($file) : undef,
        retry    => 0,
        fail     => $fs->{pass} ? 0 : 1,
        stamp    => $fs->{stamp},
        times    => $fs->{times},
    };
}

1;
```

- [ ] **Step 2.4: Run the test, verify it passes.** Run: `perl -Ilib -It2clib t/unit/Test2/Harness2/Collector/JobReader.t` → PASS.

- [ ] **Step 2.5: Commit.**

```bash
git add lib/Test2/Harness2/Collector/JobReader.pm t/unit/Test2/Harness2/Collector/JobReader.t
git commit -m "feat(collector): JobReader tails a Test2-Collector events.jsonl.zst"
```

---

## Task 3: Runner runs each test under `Test2::Collector::collect`

Replace the Formatter::Stream / scattered-files execution with a per-job collector that writes `events.jsonl.zst`. The runner's forked job process becomes the collector parent; `collect()` forks the actual test child.

**Files:**
- Modify: `lib/Test2/Harness2/Runner/Job.pm` (`cli_options` ~466, `env_vars` ~518, `spawn_params` ~116, `set_exit` ~585, the timeout-file/`et_file`/`pet_file` accessors, `event_dir`/`use_stream` usage)
- Read first: `lib/Test2/Harness2/Runner/Job.pm` in full, `lib/Test2/Harness2/Util/IPC.pm` `_run_cmd_fork` (~68-114) and how `command => sub {...}` / `run_file` runs the test in the forked child, and `lib/Test2/Harness2/Runner.pm` `run_job` (~456) + `check_timeouts` (~152).

- [ ] **Step 3.1: Add the events-file path + collector spawn.** Give the job an `events_file` accessor and a method that runs the test under a collector. Add to `Runner/Job.pm`:

```perl
sub events_file {
    my $self = shift;
    return $self->{+EVENTS_FILE} //= File::Spec->catfile($self->job_dir, 'events.jsonl.zst');
}

# Runs in the forked job child. Becomes the Test2-Collector collector parent;
# collect() forks the real test child (run_sub keeps preloaded modules; exec
# for the non-preload path) and records the full stream into events.jsonl.zst.
sub run_under_collector {
    my $self = shift;

    require Test2::Collector;
    require Test2::Collector::Recorder::Zstd;

    my $settings = $self->{+SETTINGS};

    my %common = (
        name               => $self->rel_file,
        is_test            => 1,
        run_uuid           => $self->run->run_id,
        try                => $self->is_try,
        record_transitions => 1,
        recorder           => Test2::Collector::Recorder::Zstd->new(file => $self->events_file),
        child_env          => $self->env_vars,
        chdir              => $self->ch_dir,
        io_events          => $self->io_events ? 1 : 0,
        ($self->use_timeout && $self->event_timeout)     ? (silence_timeout  => $self->event_timeout)     : (),
        ($self->use_timeout && $self->post_exit_timeout) ? (lifetime_timeout => $self->post_exit_timeout) : (),
    );

    my $info = Test2::Collector::collect(%common, $self->collector_target);
    return $info;
}

# run_sub for the fork/preload path; exec for binary/non-perl/no-fork.
sub collector_target {
    my $self = shift;
    my $task = $self->{+TASK};

    if ($task->{binary} || $task->{non_perl}) {
        my $file = clean_path($self->ch_dir ? $self->file : $self->rel_file);
        my @cmd  = ($file, $self->args);
        unshift @cmd => $^X if $task->{non_perl} && !(-x $file) && !$task->{binary};
        return (exec => \@cmd);
    }

    if ($self->use_fork) {
        return (run => sub { $self->run_file });
    }

    return (exec => [
        $^X,
        $self->cli_includes,
        $settings_nytprof($self),
        $self->switches,
        $self->cli_options,
        $self->file,
        $self->args,
    ]);
}
```

(Where `$settings_nytprof` is `$self->{+SETTINGS}->runner->nytprof ? ('-d:NYTProf') : ()` — inline it; shown as a helper only for readability.)

- [ ] **Step 3.2: Strip Formatter::Stream from `cli_options` + `env_vars`.** The collector owns event capture; the test child no longer writes its own event files. Remove the `use_stream`/`T2_FORMATTER=Stream`/`T2_STREAM_*` bits:
  - In `cli_options` (~466) delete the `$self->use_stream ? ("-MTest2::Formatter::Stream=...") : ()` line. Keep the UUID/MemUsage/load_import/load lines. (io_events is now handled by `collect(io_events => ...)`, so also delete the `$self->io_events ? ('-MTest2::Plugin::IOEvents') : ()` line — Test2-Collector's formatter handles io-events.)
  - In `env_vars` (~518) delete the `$self->use_stream ? (T2_FORMATTER => 'Stream', T2_STREAM_DIR => ..., T2_STREAM_JOB_ID => ...) : ()` line. Keep PERL5LIB/TEST2_JOB_DIR/HARNESS_* etc. (Do NOT set `T2_FORMATTER` — `collect()` sets `T2_FORMATTER=Collector` in the test child itself.)

- [ ] **Step 3.3: Route the job child through `run_under_collector`.** In the spawn path, the forked child must call `run_under_collector` and exit with the collector's status instead of exec-ing the test directly. Concretely: change `spawn_params` so `command` is a coderef that runs the collector and exits:

```perl
    # The forked child becomes the collector parent.
    command => sub {
        my $info = $self->run_under_collector;
        my $ok   = $info->{collector}{ok} ? 0 : 255;
        POSIX::_exit($ok);
    },
```

  Remove the `$out_fh`/`$err_fh` stdout/stderr file handles from `spawn_params` (the collector captures the child's stdout/stderr internally; the job no longer writes `stdout`/`stderr` files). Keep `stdin` wiring only if a test stdin/input is configured — pass it through `collect(stdin => ...)` instead; otherwise drop. Verify against `Util/IPC.pm` `_run_cmd_fork`: a `command => sub {...}` that calls `POSIX::_exit` never returns, so the `exec` fallthrough is not reached.

- [ ] **Step 3.4: Drop the exit-file + timeout-file writing.** The collector records exit (`harness_process_exit`) and timeouts (`harness_timeout`) into the events file. Remove `set_exit`'s `write_file_atomic($job_dir/exit, ...)` body (~585-596) — keep `SUPER::set_exit` so the runner's own bookkeeping still works, but stop writing the `exit` file. In `Runner.pm` `check_timeouts` (~152), stop writing `et_file`/`pet_file` (the collector enforces silence/lifetime timeouts itself now); the runner still reaps and may still SIGKILL a stuck collector parent as a backstop — keep the kill, drop the file writes. Remove the now-unused `et_file`/`pet_file`/`event_dir` accessors if nothing references them after this task (grep first).

- [ ] **Step 3.5: Smoke the producer.** Run a single real test through the runner and confirm `events.jsonl.zst` appears and contains assertions + transitions + final_state + process_exit. Use an existing integration helper or:

```bash
perl -Ilib -It2clib -e '
  # minimal: rely on integration test in Task 8; here just confirm compile + that
  # Runner/Job loads and events_file builds a path.
  require Test2::Harness2::Runner::Job; print "Job loads\n";
'
```

  Full producer verification happens via the integration suite in Task 8 (the runner is hard to unit-drive). Ensure `perl -Ilib -It2clib -c lib/Test2/Harness2/Runner/Job.pm` and `Runner.pm` are clean.

- [ ] **Step 3.6: Commit.**

```bash
git add lib/Test2/Harness2/Runner/Job.pm lib/Test2/Harness2/Runner.pm
git commit -m "feat(runner): run each test under Test2::Collector, emit events.jsonl.zst"
```

---

## Task 4: Gatherer consumes `JobReader` + run-level rollup

Swap `JobDir` for `JobReader` in `Test2::Harness2::Collector`, and add the run-level aggregator that emits `harness_final` at the end (replacing the deleted auditor process).

**Files:**
- Modify: `lib/Test2/Harness2/Collector.pm` (`jobs` ~277-348 JobDir instantiation; `process` ~54-133 loop + final emission)
- Read first: the verbatim `jobs`/`process` from the explore output above.

- [ ] **Step 4.1: Instantiate `JobReader` instead of `JobDir`.** In `jobs` (~340), replace the `Test2::Harness2::Collector::JobDir->new(...)` construction with:

```perl
        $jobs->{$job_try} = Test2::Harness2::Collector::JobReader->new(
            job_id      => $job_id,
            job_try     => $job->{is_try} // 0,
            run_id      => $self->{+RUN_ID},
            file        => $file,
            events_file => File::Spec->catfile($self->{+RUN_DIR}, $job_try, 'events.jsonl.zst'),
        );
```

  Add `use Test2::Harness2::Collector::JobReader;` at the top and remove `use Test2::Harness2::Collector::JobDir;`. The `poll`/`done`/`job_root`-cleanup loop in `process` keeps working — but `JobReader` has no `job_root`; change the cleanup block to remove the job dir via the events_file's parent dir: `my $job_path = File::Spec->catdir($self->{+RUN_DIR}, $job_try);` (replace the `$jdir->job_root` reference).

- [ ] **Step 4.2: Track per-job final_state for the rollup.** As the gatherer emits events, capture each job's verdict. In `process`, where each event from `poll` is dispatched (`$self->{+ACTION}->($event)`), tee the verdict:

```perl
            for my $event ($jdir->poll($self->settings->collector->max_poll_events // 1000)) {
                $self->_note_verdict($event);
                $self->{+ACTION}->($event);
                $e_count++;
            }
```

  Add the rollup state + helper to `Collector.pm`:

```perl
# job_id => {file => ..., pass => bool, retry => bool, seen => 1}
sub _note_verdict {
    my $self = shift;
    my ($event) = @_;
    my $fd = $event->facet_data or return;

    if (my $end = $fd->{harness_job_end}) {
        my $jid = $event->job_id;
        $self->{+VERDICTS}{$jid} = {
            file => $end->{file},
            fail => $end->{fail} ? 1 : 0,
            try  => $event->job_try,
        };
    }
}
```

  (Add `+verdicts` to the HashBase block; `$self->{+VERDICTS} //= {}` in `init`.)

- [ ] **Step 4.3: Emit `harness_final` at the end.** Where `process` currently signals end (`$self->{+ACTION}->(undef) if ...` ~128), emit the run-level rollup event first:

```perl
    $self->{+ACTION}->($self->_final_event) if $self->{+JOBS_DONE} && $self->{+TASKS_DONE};
    $self->{+ACTION}->(undef)               if $self->{+JOBS_DONE} && $self->{+TASKS_DONE};
```

  with:

```perl
sub _final_event {
    my $self = shift;

    my $v = $self->{+VERDICTS} // {};
    my @failed  = map  { [$_, $v->{$_}{file}] } grep { $v->{$_}{fail} } sort keys %$v;
    my $pass    = @failed ? 0 : 1;

    return $self->_harness_event(0, undef, time,
        harness_final => {
            pass    => $pass,
            failed  => \@failed,
            retried => [],   # retry accounting still flows via job_end.retry; populate when retries land in this stream
            halted  => [],
            unseen  => [],
        },
    );
}
```

  (Match `_harness_event`'s existing signature — it is used elsewhere in this file at ~247/316; reuse it verbatim.) Retry/halt/unseen lists: keep parity with what `Auditor::finish` produced (read the deleted-in-Task-7 `Auditor::finish` ~91-124 now and port its failed/retried/halted/unseen derivation into `_final_event` using `$self->{+VERDICTS}` + `$self->{+PENDING}`; the test command's finalizer reads only `harness_final` so the shape must match exactly).

- [ ] **Step 4.4: Verify compile + the JobReader test still passes.** Run: `perl -Ilib -It2clib -c lib/Test2/Harness2/Collector.pm` and `perl -Ilib -It2clib t/unit/Test2/Harness2/Collector/JobReader.t`.

- [ ] **Step 4.5: Commit.**

```bash
git add lib/Test2/Harness2/Collector.pm
git commit -m "feat(collector): gatherer reads JobReader + emits run-level harness_final"
```

---

## Task 5: Remove the auditor process; wire collector → renderer

**Files:**
- Modify: `lib/App/Yath2/Command/test.pm` (`start_auditor` ~874-896 + call site; the pipe accessors `auditor_reader`/`collector_writer`/`renderer_reader`/`auditor_writer` ~148-178; `render` ~304 reads from `renderer_reader`)
- Read first: the verbatim pipe topology + `render` from the explore output.

- [ ] **Step 5.1: Collapse the pipeline to two ends.** The auditor process is gone; the gatherer (collector) now emits the fully-formed stream (including `harness_job_end`/`harness_final`). Wire the collector's stdout directly to the renderer's input. Rewrite the pipe accessors so there is ONE pipe: gatherer-writes → renderer-reads. Replace the four accessors with:

```perl
sub collector_writer {
    my $self = shift;
    return $self->{+COLLECTOR_WRITER} if $self->{+COLLECTOR_WRITER};
    pipe($self->{+RENDERER_READER}, $self->{+COLLECTOR_WRITER}) or die "Could not create pipe: $!";
    _resize_pipe($self->{+COLLECTOR_WRITER});
    return $self->{+COLLECTOR_WRITER};
}

sub renderer_reader {
    my $self = shift;
    return $self->{+RENDERER_READER} if $self->{+RENDERER_READER};
    pipe($self->{+RENDERER_READER}, $self->{+COLLECTOR_WRITER}) or die "Could not create pipe: $!";
    _resize_pipe($self->{+COLLECTOR_WRITER});
    return $self->{+RENDERER_READER};
}
```

  Delete `auditor_reader` and `auditor_writer` and their HashBase slots (`AUDITOR_READER`/`AUDITOR_WRITER`). `start_collector` already spawns with `stdout => $self->collector_writer` — that now feeds the renderer directly.

- [ ] **Step 5.2: Delete `start_auditor` + its call.** Remove the whole `start_auditor` sub (~874-896) and the line that calls it (grep `start_auditor` — it is invoked in the command's run/setup path alongside `start_collector` and `start_renderer`/`render`). The pipeline is now: `start_collector` (gatherer) → `render` (renderer reads `renderer_reader`).

- [ ] **Step 5.3: Verify `render` is unchanged and correct.** `render` (~304) reads `renderer_reader`, decodes each line into `Test2::Harness2::Event`, runs annotate/handle plugins, logs, and captures `harness_final` into `FINAL_DATA`. No change needed — it already consumes the stream the gatherer now produces. Confirm the `harness_final`/`harness_job_launch`/`assert` reads still match (they do; the gatherer emits all three).

- [ ] **Step 5.4: Verify compile.** `perl -Ilib -It2clib -c lib/App/Yath2/Command/test.pm`.

- [ ] **Step 5.5: Commit.**

```bash
git add lib/App/Yath2/Command/test.pm
git commit -m "refactor(test): drop the auditor process, wire gatherer -> renderer directly"
```

---

## Task 6: Renderer facet adaptation

The renderer consumed 1.0 facets. Most are bridged by `JobReader` (harness_job_exit/end) or unchanged (assert/plan/control/info/from_tap). The genuine delta is subtest structure: Test2-Collector's Assembler nests subtests into `parent.children` and uses `harness.{subtest_start,subtest_started,subtest_end,subtest_closed}` markers.

**Files:**
- Modify: `lib/Test2/Harness2/Renderer/Formatter.pm` (and any other `Renderer/*` that reads `harness.subtest_*` or `from_tap`/`harness_job_*`)
- Read first: grep the renderer tree for `subtest_start`, `subtest_end`, `parent`, `harness_job_exit`, `harness_job_end`, `from_tap`, `harness_final`.

- [ ] **Step 6.1: Inventory the renderer's facet reads.** Run:

```bash
grep -rn 'subtest_start\|subtest_end\|->{parent}\|harness_job_exit\|harness_job_end\|harness_final\|from_tap\|from_stream\|harness_state_transition' lib/Test2/Harness2/Renderer/
```

  For each hit, confirm whether the facet is provided as-before (job_exit/end via JobReader, from_tap shared) or changed (subtest markers, new from_stream). List the adaptation needed.

- [ ] **Step 6.2: Adapt subtest handling.** Where the renderer keys off `harness.subtest_start`/`harness.subtest_end`, accept the Test2-Collector marker set (`subtest_start`/`subtest_started`/`subtest_end`/`subtest_closed`) and the `parent.children` nesting the Assembler produces. Keep the visible output equivalent (nested subtest rendering). Show the concrete edit for each hit found in 6.1 — drive by the actual renderer code (it was not rewritten in chunk 2, so it is 1.0-shaped). If a renderer reads raw test output, add `from_stream` alongside `from_tap` for STDOUT/STDERR line display.

- [ ] **Step 6.3: Verify with a rendered run.** This is exercised by the integration suite (Task 8); for a fast loop, build a fixture events.jsonl.zst with a nested subtest (extend the Task 2 fixture pattern) and feed it through the renderer in a small scratch script under `agent_scripts/`. Confirm nested output renders.

- [ ] **Step 6.4: Commit.**

```bash
git add lib/Test2/Harness2/Renderer/
git commit -m "refactor(renderer): adapt to Test2-Collector subtest/stream facets"
```

---

## Task 7: Delete the in-tree pipeline machinery

**Files (delete):**
- `lib/Test2/Harness2/Auditor.pm`
- `lib/Test2/Harness2/Auditor/Watcher.pm` (+ any other `lib/Test2/Harness2/Auditor/*`)
- `lib/Test2/Harness2/Collector/JobDir.pm`
- `lib/Test2/Harness2/Collector/TapParser.pm`
- `lib/Test2/Formatter/Stream.pm`
- `lib/App/Yath2/Command/auditor.pm`

- [ ] **Step 7.1: Confirm no live references.** Run:

```bash
grep -rn 'Auditor\|JobDir\|TapParser\|Formatter::Stream\|Command::auditor\|->auditor\b' lib/ scripts/ | grep -v 'Collector/JobReader\|# '
```

  Every remaining hit must be a comment or the files being deleted. The `auditor` command name resolution (App::Yath2 `_command_from_argv` / `load_command`) needs no change — removing the file makes it simply not a command. Verify nothing in `test.pm`/`Runner*`/`Collector.pm` still requires these (Tasks 3–5 removed the live uses; this grep is the safety net). If `Auditor::finish`'s rollup logic was not yet fully ported in Task 4.3, port it now before deleting.

- [ ] **Step 7.2: Delete.**

```bash
git rm lib/Test2/Harness2/Auditor.pm lib/Test2/Harness2/Auditor/Watcher.pm \
       lib/Test2/Harness2/Collector/JobDir.pm lib/Test2/Harness2/Collector/TapParser.pm \
       lib/Test2/Formatter/Stream.pm lib/App/Yath2/Command/auditor.pm
# include any other lib/Test2/Harness2/Auditor/* found in 7.1
```

- [ ] **Step 7.3: Verify compile of the tree.** Run:

```bash
for f in $(git ls-files 'lib/**/*.pm'); do perl -Ilib -It2clib -c $f 2>&1 | grep -v 'syntax OK' && echo "FAIL $f"; done
echo done
```

  Expected: no FAIL lines (the `grep -v` swallows the OK lines; only errors print).

- [ ] **Step 7.4: Commit.**

```bash
git commit -m "refactor!: remove in-tree auditor, parsers, JobDir, stream formatter, auditor command"
```

---

## Task 8: Tests — delete dead, update, drive suite green

**Files:**
- Delete: unit tests for removed modules — `t/unit/Test2/Harness2/Auditor*.t` (and `Auditor/` subdir), `t/unit/Test2/Harness2/Collector/JobDir.t` (if present), `t/unit/Test2/Harness2/Collector/TapParser.t`, any `t/unit/Test2/Formatter/Stream.t`, `t/unit/App/Yath2/Command/auditor.t`.
- Modify: integration tests as failures dictate.

- [ ] **Step 8.1: Find + delete dead unit tests.** Run:

```bash
grep -rln 'Auditor\|JobDir\|TapParser\|Formatter::Stream\|Command::auditor' t/unit/ t/integration/
```

  `git rm` the unit tests whose sole subject is a deleted module. For integration tests that merely mention these, fix the reference (they should be exercising behavior, not the removed internals).

- [ ] **Step 8.2: Run the unit suite, fix failures.** Run: `prove -Ilib -It2clib -j16 -r t/unit/ 2>&1 | tail -20`. Fix each failure: most are old facet/shape assumptions — update to the new event stream. Add `use lib 't2clib';` to any test that loads `Test2::Collector*`.

- [ ] **Step 8.3: Run the integration suite, fix failures.** Run: `prove -Ilib -It2clib -j16 -r t/integration/ 2>&1 | tail -30`. These exercise the full new pipeline end-to-end (test/coverage/retry/concurrency/reload/preload). For each failure decide: (a) real bug in the swap → fix the code (Task 3/4/6); (b) intentional facet/format change → update the test, noting it in the commit body. Pay attention to: subtest rendering, retry behavior (per-try events.jsonl.zst), coverage (Cover plugin still injects via run->load_import; its events now come through the collector), timeouts (silence/lifetime via collect()).

- [ ] **Step 8.4: Full suite green.** Run: `prove -Ilib -It2clib -j16 -r t/ 2>&1 | tail -5` → `Result: PASS`. Iterate until green. Capture the final output.

- [ ] **Step 8.5: Commit.**

```bash
git add -A t/
git commit -m "test: update suite for the Test2-Collector pipeline; delete dead tests"
```

---

## Task 9: Docs + final gates

**Files:**
- Modify: `TODO_STEPS.md`, `ARCHITECTURE.md` (§4.1), `AGENTS.md`/testing note if the test command now needs `-It2clib`.

- [ ] **Step 9.1: Pre-review gates.** Run `perl agent_scripts/audit-methods-not-functions lib`, `perl agent_scripts/audit-readonly-attrs lib`, and `podchecker` on every touched/new `.pm`. Resolve all hits (hard stops per AGENTS.md). Re-run the suite if code changed.

- [ ] **Step 9.2: Update testing instructions.** If `Test2::Collector*` is now loaded by the live runtime (not just tests), the canonical test command becomes `prove -Ilib -It2clib -j16 -r t/`. Update the testing note in `AGENTS.md` and `TODO_STEPS.md` "Ground rules" to include `-It2clib` (and note scripts add `t2clib` to `@INC` themselves).

- [ ] **Step 9.3: TODO_STEPS.md.** Flip chunk 3 row to ✅ with commit refs; update "Current state" (tests now run under Test2-Collector; in-tree auditor/parsers/JobDir/stream formatter removed; collector pipeline output is a single events.jsonl.zst per job containing events+transitions; gatherer tails those files; run-level rollup in the gatherer). Add a "Done so far" chunk-3 entry. Update "Next" → chunk 4 (collectors wrap every yath-started process).

- [ ] **Step 9.4: ARCHITECTURE.md §4.1 (Collectors).** Retag from `[target]` toward done for the parts now real: Test2-Collector executes/audits tests; the yath-side collector reads the `.jsonl.zst` the collector writes instead of parsing/auditing raw events. Note the `record_transitions` decision (one file holds events+transitions) and that the live transition socket channel (§4.3) + collectors-for-all-processes (§4.2) remain `[target]` (chunks 4–5). Record the Test2-Collector dist change (transitions→recorder) as an addendum if it deviates from anything §4.1/§5.1 stated.

- [ ] **Step 9.5: Commit.**

```bash
git add TODO_STEPS.md ARCHITECTURE.md AGENTS.md
git commit -m "docs: mark chunk 3 (collector swap) complete"
```

- [ ] **Step 9.6: Finish the branch.** Per AGENTS.md, integrate the worktree branch with a merge commit (`git merge --no-ff collector-swap` into `2.0d`) — but only after the user reviews. Surface the branch for review rather than auto-merging (foundations-era worktree policy: the user directed this worktree explicitly; confirm merge timing with them).

---

## Self-review notes

- **Spec coverage:** dist change (T1), gatherer reader (T2), producer/runner (T3), gatherer rollup+swap (T4), auditor-process removal (T5), renderer adaptation (T6), deletions (T7), tests (T8), docs+gates (T9). Facet adaptation: T2 (synthesis) + T6 (renderer). Run-level verdict: T4.3 (ported from the about-to-be-deleted `Auditor::finish`).
- **Cross-task contracts:** `JobReader` (T2) emits `harness_job_exit`/`harness_job_end` consumed by the gatherer rollup (T4) and renderer (T6); the gatherer emits `harness_final` (T4.3) consumed by `render`'s `FINAL_DATA` (unchanged, T5.3). `events_file` path is `RUN_DIR/$job_id+$try/events.jsonl.zst`, written by the runner (T3.1 `events_file`) and read by the gatherer (T4.1) — same construction, verified identical.
- **Known risk / judgment calls baked in:** the runner's forked job child becomes the collector parent via a `command => sub{...}` that `POSIX::_exit`s (T3.3) — the implementer must confirm `_run_cmd_fork` honors a coderef command that never returns (it does: it maps CODE then execs, and `_exit` pre-empts that). Retry/halt/unseen rollup parity (T4.3) must match the deleted `Auditor::finish` shape exactly — port before deleting (T7.1 guard).
- **If Test2-Collector is found missing a behavior** the harness relied on (a timeout nuance, an exit detail, a facet field), flag it for the user per the spec's "Open items" rather than working around it in the harness.
