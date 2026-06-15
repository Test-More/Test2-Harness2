# Test2-Harness2 Web UI — Demo

This directory holds sample yath event logs (`*.jsonl.bz2`) you can load into the
inlined Test2-Harness2 web UI to see it in action without running any tests of
your own.

The supported way to launch the demo is the **`yath server`** command, which can
spin up a throwaway ("ephemeral") database, import a log into it, and serve the
web UI — all in one step. SQLite is used by default, so nothing else needs to be
installed or configured.

---

## Requirements

- A built checkout of this distribution. Run the commands below **from the
  repository root** (not from inside `demo/`) — in a dev checkout the UI finds
  its assets and templates in `share/` relative to the current directory.
- The `yath` launcher on your `PATH` (from `App::Yath::Script`).
- Perl modules: `DBD::SQLite`, `DBIx::Class` (+ the schema components),
  `DBIx::QuickDB`, `Plack`, `Starman`, `Text::Xslate`, `Router::Simple`.
  (These are declared in `dist.ini`; install with your usual CPAN client if
  missing.)

---

## Quick start

From the repository root:

```
yath server --ephemeral=SQLite --port 8080 demo/simple-fail.jsonl.bz2
```

Then open <http://localhost:8080/> in a browser.

This:

1. creates an ephemeral SQLite database (deleted on exit),
2. imports `demo/simple-fail.jsonl.bz2` into it,
3. serves the web UI on port 8080.

Press `Ctrl-C` to stop the server and discard the ephemeral database.

### Useful flags

- `--ephemeral=SQLite` — use a throwaway SQLite DB. Other values: `PostgreSQL`,
  `MySQL`, `MariaDB`, `Percona`, or `Auto` (tries PostgreSQL then MySQL). SQLite
  needs no setup, so it is the easiest for a demo.
- `--port N` — port to listen on. Omit to let it choose; the chosen URL is
  printed at startup.
- `--single-user` — no login/registration; everything is owned by a `root` user.
  Good for a local demo.
- `--single-run` — pin the UI to the single imported run (skips the dashboard /
  run list). Omit it to browse a run list instead.
- `--no-upload` — disable the upload form (you are viewing a fixed log).
- `--workers N` — number of web workers (default: CPU count). `--workers 1` is
  fine for a demo.
- `--daemon` — detach and run in the background instead of the foreground. In
  the foreground (no `--daemon`) you stop it with `Ctrl-C`.

You can pass more than one log to import several runs at once:

```
yath server --ephemeral=SQLite --port 8080 demo/simple-pass.jsonl.bz2 demo/simple-fail.jsonl.bz2
```

---

## Sample logs

Each file is a complete yath run captured as a JSONL event log. Pick whichever
exercises the part of the UI you want to see.

| Log | What it shows |
|-----|---------------|
| `tiny.jsonl.bz2` | The smallest run — quickest thing to load. |
| `simple-pass.jsonl.bz2` | A small, all-passing run. |
| `simple-fail.jsonl.bz2` | A small run with failures (red rows, failure detail). |
| `fail_once.jsonl.bz2` | A test that fails then passes on retry. |
| `subtests.jsonl.bz2` | Nested subtests (expand/collapse in the event view). |
| `concurrent.jsonl.bz2` | Multiple jobs running concurrently. |
| `coverage.jsonl.bz2` | A run carrying source-coverage data (Coverage view). |
| `fields.jsonl.bz2` | Custom harness/job fields. |
| `image.jsonl.bz2` | A run with an attached binary/image artifact. |
| `table.jsonl.bz2` | Output containing rendered tables. |
| `tap.jsonl.bz2` | Raw TAP-style output. |
| `timing.jsonl.bz2` | Timing / duration data (durations view). |
| `moose.jsonl.bz2` | A larger, real-world-style run (Moose-based tests). |
| `large.jsonl.bz2` | A big run with many tests/events (stress the tables). |
| `nouuid.jsonl.bz2` | An older-format run without event UUIDs. |
| `fake.jsonl.bz2` | Synthetic data for exercising the UI. |

Several logs have a matching subdirectory here (e.g. `coverage/`, `subtests/`)
containing the test source files that produced them, for reference.

---

## Using the UI

- **Run list / dashboard** (when not using `--single-run`): lists imported runs
  with pass/fail counts and status; click a run to open it.
- **Run view**: the jobs in the run, each with status, file name, and tools.
  Click a job to see its events.
- **Event view**: the assertions, diagnostics, and subtests for a job. Failing
  subtests expand automatically; use the tag filters to show/hide event types.
- **Coverage / Durations / Fields**: available when the loaded log carries that
  data (e.g. `coverage.jsonl.bz2`, `timing.jsonl.bz2`, `fields.jsonl.bz2`).
- The tables are sortable and searchable (DataTables); charts render where the
  data supports them.

---

## Alternative: serve an existing database with plackup (`demo.psgi`)

If you already have a populated UI database, you can serve it with any PSGI
server instead of `yath server`. `demo.psgi` builds the same app against the DSN
in `HARNESS_UI_DSN`. Run it from the repository root:

```
HARNESS_UI_DSN='dbi:SQLite:dbname=/path/to/ui.db' plackup demo/demo.psgi
```

The driver is auto-detected from the DSN. `demo.psgi` does **not** create or
import anything — it only serves an existing database. For the all-in-one
create+import+serve flow, use `yath server` as above.

---

## Notes

- The ephemeral database and any temporary files are removed when the server
  exits cleanly (`Ctrl-C` / `SIGTERM`).
- SQLite is the default and needs no external service. Postgres/MySQL/MariaDB/
  Percona are also supported via `--ephemeral=<Driver>` (and require the
  corresponding `DBD::*` driver and server).
</content>
