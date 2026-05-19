# Minimal `yath test` Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the existing WIP `App::Yath2::Command::test` with a minimal implementation that runs a supplied list of test files through a `Test2::Harness2` child service, prints the work directory, and exits 0 iff every job passed.

**Architecture:**
- `yath test FILE1 FILE2 ...` takes positional args only (no option parsing in this pass).
- The command spawns a `Test2::Harness2` child via `Test2::Harness2->spawn(...)`, hands it a `test_run` payload with the supplied files, and requests `finish_after_initial_run => 1` so the service exits once the run completes.
- Concurrency is fixed: a single `Test2::Harness2::Resource::JobCount->new(slots => 16)`.
- Three loggers are wired:
  - A harness-level JSONL logger (`loggers` slot) so the parent can tail `job_completed` events for pass/fail aggregation.
  - Per-test JSONL and JSON loggers (`test_loggers` slot) written under `%LOG_DIR%`.
- No renderer. No artifact cleanup. `settings->workspace->keep_dirs` is forced to true before returning so `App::Yath2::run_command` skips the workdir removal.
- Pass/fail is computed by reading the harness JSONL log after `$spawn->wait` and counting `kind => 'job_completed'` events with `pass => 0`.

**Tech Stack:** Perl 5.42, `Test2::Harness2`, `Test2::Harness2::Resource::JobCount`, `Test2::Harness2::Collector::Logger::{JSON,JSONL}`, `Test2::Harness2::TestFile`, `Getopt::Yath`, `Role::Tiny::With`, `Object::HashBase`.

---

## File Structure

- **Replace:** `lib/App/Yath2/Command/test.pm` — minimal command class, consumes `App::Yath2::Role::Command`. Everything currently in that file is WIP from the old tree and gets thrown out.
- **Read-only reference (do not modify):**
  - `lib/Test2/Harness2.pm` (`spawn`, `start`, `request_handler_queue_test_run`, `_handle_job_complete`)
  - `lib/Test2/Harness2/Spawn.pm` (`queue_test_run`, `finish`, `wait`)
  - `lib/Test2/Harness2/Resource/JobCount.pm`
  - `lib/Test2/Harness2/Collector/Logger/JSON.pm`
  - `lib/Test2/Harness2/Collector/Logger/JSONL.pm`
  - `lib/Test2/Harness2/TestFile.pm`
  - `lib/App/Yath2/Options/Workspace.pm` (`workdir`, `keep_dirs`)
  - `lib/App/Yath2.pm:560-580` (where `run_command` performs workdir cleanup)
  - `lib/App/Yath2/Role/Command.pm`
  - `lib/App/Yath2/Command/hello.pm` (reference for how a command wires `Getopt::Yath` + role)

No tests are created by this plan. A manual smoke test at the end verifies behavior.

---

### Task 1: Replace `test.pm` with a skeleton command class

**Files:**
- Modify: `lib/App/Yath2/Command/test.pm` (full replacement)

- [ ] **Step 1: Overwrite `lib/App/Yath2/Command/test.pm` with the skeleton**

```perl
package App::Yath2::Command::test;
use strict;
use warnings;

our $VERSION = '2.000011';

use Object::HashBase qw{
    <settings
    <args
    <env_vars
    <option_state
    <plugins
};

use File::Spec();
use Carp qw/croak/;

use Test2::Harness2();
use Test2::Harness2::TestFile();
use Test2::Harness2::Resource::JobCount();

use Getopt::Yath;
include_options(
    'App::Yath2::Options::Workspace',
    'App::Yath2::Options::Yath',
);

use Role::Tiny::With;
with 'App::Yath2::Role::Command';

sub args_include_tests { 1 }
sub group              { 'test' }
sub summary            { 'Run a list of test files' }

sub description {
    return <<"    EOT";
Minimal test runner. Pass a list of test files; they are executed via a
Test2::Harness2 child service with 16-slot job concurrency, JSON and JSONL
loggers, and no cleanup of the work directory. Exits 0 if every test passed,
non-zero otherwise.
    EOT
}

sub run {
    my $self = shift;

    die "TODO: implement in Task 2\n";
}

1;

__END__

=head1 POD IS AUTO-GENERATED
```

- [ ] **Step 2: Compile-check**

Run: `perl -Ilib -c lib/App/Yath2/Command/test.pm`
Expected: `lib/App/Yath2/Command/test.pm syntax OK`

- [ ] **Step 3: Commit**

```bash
git add lib/App/Yath2/Command/test.pm
git commit -m "$(cat <<'EOF'
test: replace with minimal role-based skeleton

Discard the leftover pre-rewrite contents and set up a skeleton that
consumes App::Yath2::Role::Command, includes the Workspace + Yath
option groups, and accepts test files as positional args. Run logic
lands in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Implement `run()` — spawn the harness and execute the files

**Files:**
- Modify: `lib/App/Yath2/Command/test.pm` (replace the `die "TODO..."` body of `run`)

- [ ] **Step 1: Replace `sub run` with the real implementation**

Replace the `sub run { ... die "TODO: implement in Task 2\n"; }` block with the following body. Everything else in the file stays untouched.

```perl
sub run {
    my $self = shift;

    my $settings = $self->{+SETTINGS};
    my $args     = $self->{+ARGS} // [];

    die "No test files supplied.\nUsage: yath test FILE [FILE ...]\n"
        unless @$args;

    my @files;
    for my $file (@$args) {
        die "Not a readable test file: $file\n" unless -f $file && -r _;
        push @files => Test2::Harness2::TestFile->new(file => $file);
    }

    my $workdir = $settings->workspace->workdir;
    my $logdir  = File::Spec->catdir($workdir, 'logs');

    # Harness-level log so the parent can tally job_completed events.
    my $harness_log = File::Spec->catfile($workdir, 'harness.jsonl');

    my $spawn = Test2::Harness2->spawn(
        workdir                  => $workdir,
        resources                => [Test2::Harness2::Resource::JobCount->new(slots => 16)],
        loggers                  => [
            ['Test2::Harness2::Collector::Logger::JSONL', output_file => $harness_log],
        ],
        test_loggers => [
            ['Test2::Harness2::Collector::Logger::JSONL', output_file => '%LOG_DIR%/%JOB_TRY%.jsonl'],
            ['Test2::Harness2::Collector::Logger::JSON',  output_file => '%LOG_DIR%/%JOB_TRY%.json'],
        ],
        test_run                 => {files => \@files},
        finish_after_initial_run => 1,
    );

    $spawn->wait;

    my $pass = $self->_aggregate_pass($harness_log);

    # Prevent App::Yath2::run_command from removing the workdir on exit.
    $settings->workspace->create_option(keep_dirs => 1);

    print "Work directory: $workdir\n";
    print "Harness log:    $harness_log\n";

    return $pass ? 0 : 1;
}
```

- [ ] **Step 2: Add the `_aggregate_pass` helper at the bottom of the package (before `1;`)**

```perl
sub _aggregate_pass {
    my $self = shift;
    my ($harness_log) = @_;

    open(my $fh, '<', $harness_log) or die "Could not open '$harness_log': $!";

    require Test2::Harness2::Util::JSON;
    my $decode = \&Test2::Harness2::Util::JSON::decode_json;

    my $seen_any = 0;
    my $all_pass = 1;
    while (my $line = <$fh>) {
        chomp $line;
        next unless length $line;
        my $ev = $decode->($line);
        next unless ref($ev) eq 'HASH' && ($ev->{kind} // '') eq 'job_completed';
        $seen_any = 1;
        $all_pass = 0 unless $ev->{pass};
    }
    close($fh);

    die "Harness log contained no job_completed events; run produced no results.\n"
        unless $seen_any;

    return $all_pass;
}
```

- [ ] **Step 3: Compile-check**

Run: `perl -Ilib -c lib/App/Yath2/Command/test.pm`
Expected: `lib/App/Yath2/Command/test.pm syntax OK`

- [ ] **Step 4: Commit**

```bash
git add lib/App/Yath2/Command/test.pm
git commit -m "$(cat <<'EOF'
test: spawn Test2::Harness2 and tally pass/fail

Positional args are coerced to Test2::Harness2::TestFile instances and
handed to Test2::Harness2->spawn with a 16-slot JobCount resource, a
harness-level JSONL logger, and per-test JSON + JSONL loggers. After
the service exits, read the harness log, count job_completed events,
and return 0 only if every event carries pass => 1.

Forces settings->workspace->keep_dirs = 1 so App::Yath2::run_command
does not delete the work directory; prints workdir + harness log path
before returning.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Manual smoke test

**Files (temporary — delete after):**
- Create: `/tmp/yath-smoke/pass.t`
- Create: `/tmp/yath-smoke/fail.t`

- [ ] **Step 1: Write a passing test**

```bash
mkdir -p /tmp/yath-smoke
cat > /tmp/yath-smoke/pass.t <<'EOF'
use Test2::V0;
ok(1, "passes");
done_testing;
EOF
```

- [ ] **Step 2: Write a failing test**

```bash
cat > /tmp/yath-smoke/fail.t <<'EOF'
use Test2::V0;
ok(0, "fails on purpose");
done_testing;
EOF
```

- [ ] **Step 3: Run only the passing file; exit should be 0**

Run: `perl -Ilib scripts/yath test /tmp/yath-smoke/pass.t; echo "exit=$?"`
Expected:
- `Work directory: ...` line printed
- `Harness log:    ...` line printed
- final line `exit=0`

- [ ] **Step 4: Run only the failing file; exit should be non-zero**

Run: `perl -Ilib scripts/yath test /tmp/yath-smoke/fail.t; echo "exit=$?"`
Expected:
- same workdir + harness log lines printed
- final line `exit=1`

- [ ] **Step 5: Run both files; exit should be non-zero**

Run: `perl -Ilib scripts/yath test /tmp/yath-smoke/pass.t /tmp/yath-smoke/fail.t; echo "exit=$?"`
Expected: `exit=1`

- [ ] **Step 6: Inspect the preserved workdir from one of the runs**

Confirm each of the following exists and is non-empty (substitute the printed workdir path):
- `$WORKDIR/harness.jsonl` — contains at least one `"kind":"job_completed"` line per file
- `$WORKDIR/logs/runs/<RUN_ID>/<JOB_ID>/1.jsonl`
- `$WORKDIR/logs/runs/<RUN_ID>/<JOB_ID>/1.json`

Run: `grep -c '"kind":"job_completed"' $WORKDIR/harness.jsonl`
Expected: integer equal to number of test files passed on the command line for that run.

- [ ] **Step 7: Clean up the smoke-test fixtures**

```bash
rm -rf /tmp/yath-smoke
# Leave preserved work directories alone unless you want to delete them.
```

- [ ] **Step 8: No commit**

This task writes no tracked files; nothing to commit.

---

## Self-Review Notes

- **Spec coverage:**
  - "start a Test2::Harness service" → Task 2 `Test2::Harness2->spawn` call.
  - "pass in any test files we list" → Task 2 arg coercion into TestFile + `test_run => {files => ...}`.
  - "exit 0 if all tests passed" / "false if any failed" → Task 2 `_aggregate_pass` + return.
  - "enable JSON and JSONL loggers" → Task 2 `test_loggers` slot.
  - "output the work directory, do not clean up" → Task 2 `print` + `keep_dirs` override.
  - "JobCount resource, 16 concurrent" → Task 2 `resources` slot.
  - "no CLI options, no renderer" → no option groups beyond Workspace/Yath, no renderer wiring.

- **Assumptions worth flagging during execution:**
  - `settings->workspace` is populated during normal option processing because `App::Yath2::Options::Workspace` is included via `include_options`; the autofill default creates a tempdir. If the harness ever runs before option processing (it should not, since `App::Yath2::run` calls `process_args` before constructing the command), this will need revisiting.
  - `Test2::Harness2::TestFile->new(file => $path)` accepts relative paths; the harness clean-paths internally. No `clean_path` call is added here on purpose.
  - `$spawn->wait` blocks until the harness child exits. With `finish_after_initial_run => 1`, the child exits on its own after the run completes — no explicit `$spawn->finish` call is needed.
