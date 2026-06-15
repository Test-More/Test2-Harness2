# Test2-Harness UI — Playwright tests

End-to-end JS/CSS tests for the **inlined** Test2-Harness web UI (the jQuery +
jQuery-UI + DataTables + Chart.js front-end under `share/js`, `share/css`,
`share/templates`). These tests drive a **real** headless Chromium against a
**real** yath server that boots an ephemeral SQLite database, imports a demo
log, and serves the inlined Plack/Starman app.

This is a **developer / author test**. It is **NOT** part of `prove` and is not
run by the Perl test suite. CI for the distribution does not depend on Node.

## What it covers

| Spec | Asserts |
| --- | --- |
| `01-main-page.spec.ts` | Page loads, `<title>`, header `Test2-Harness-UI`, nav + UUID-lookup widget present, jQuery / DataTables / Chart.js / `t2hui` all loaded, the run table renders the imported run with the correct status/fail classes. |
| `02-run-view.spec.ts` | Drilling into the run (`/view/<id>`) renders the job table (pass + fail jobs, file names); the run-scoped stream terminates so DataTables sorting initializes on both tables; clicking a column header re-sorts the rows. |
| `03-job-events.spec.ts` | Opening a failing job (`/view/<id>/<job_uuid>`) renders the event table; a failing subtest auto-expands into nested `data-parent-id` rows; clicking a tag filter hides the matching event rows (click → DOM change). |
| `04-interactions.spec.ts` | The run "parameters" tool opens the `#free_modal` rendered by JSONFormatter and the close control hides it; the UUID lookup form submits to `/lookup`. |
| `05-css-and-chart.spec.ts` | CSS sanity: header/layout wrappers visible and positioned, stylesheets applied (computed `background-color`, `font-size`, table `border-collapse`), the run table is styled; a full-page screenshot snapshot of the main view; Chart.js is loaded and constructable. |
| `06-jobtable-regression.spec.ts` | Regression guard for the jobtable field-name bug: the run view lists every DISTINCT job row (no collapse/replace), each "Open Job" link is a real `view/<run_uuid>/<job_uuid>/<try>` URL (never `undefined`), and clicking a job row navigates to a job/events view that loads (HTTP 200). Fails on the old 1.0 assets. |

## Requirements

1. **A built/working worktree** of Test2-Harness with the Perl deps the UI
   server needs installed (DBD::SQLite, DBIx::Class, DateTime::Format::SQLite,
   DBIx::Class::InflateColumn::Serializer::JSON, Plack, Starman, Router::Simple,
   Text::Xslate, plus the bz2 log reader). The same deps gate
   `t/AI/integration/ui_server.t`.
2. `yath` on `PATH` (this repo's `scripts/yath` / installed launcher). Override
   with `YATH_BIN=/path/to/yath` if needed.
3. **Node.js + npm**, and a Chromium browser downloaded by Playwright.

The Playwright config (`playwright.config.ts`) launches the server itself via
its `webServer` block — you do **not** start it manually. It runs, from the
repo root:

```
perl -Dlib "$(command -v yath)" server \
    --ephemeral=SQLite --single-user --single-run --no-upload \
    --port 8788 --workers 1 demo/simple-fail.jsonl.bz2
```

(foreground, so Playwright owns its lifecycle). Note `-Dlib` is **yath's** own
flag, not perl's.

## Run it

```sh
cd js-tests
npm install
npx playwright install chromium
npm test
```

Useful variants:

```sh
npm run test:headed        # watch it in a real browser window
npm run report             # open the last HTML report
npx playwright test 03-job-events.spec.ts   # one spec
npx playwright test --update-snapshots       # (re)bless the screenshot baseline
```

### Configuration

| Env var | Default | Meaning |
| --- | --- | --- |
| `YATH_UI_TEST_PORT` | `8788` | Port the test server binds. |
| `YATH_BIN` | `yath` | yath launcher to invoke. |
| `YATH_UI_DEMO_LOG` | `demo/simple-fail.jsonl.bz2` | Demo log imported into the ephemeral DB. |

## Notes / gotchas

- The **all-runs** stream (`/stream`, used by the bare `/` page) stays open for
  live updates and never "completes", so on `/` the DataTables `done` hook never
  fires. The tests therefore exercise DataTables sorting on the **run-scoped**
  view (`/view/<id>`), whose stream terminates once the run is complete.
- **Fixed front-end bug (now regression-guarded):** the original `share/` assets
  were copied from the 1.0 UI, whose `jobtable.js`/`view.js` used `item.job_key`
  as the per-row DOM id and as the "Open Job" link target — but the inlined
  pre_ai server never emits `job_key`. Every job row therefore got
  `id=undefined` and collapsed to a single row (each row `replaceWith`'d the
  previous), and the open link became `view/<run>/undefined` (errored on click).
  The assets were corrected to the pre_ai contract: row id = `job_try_id`, link =
  `view/<run_uuid>/<job_uuid>/<job_try_ord>`. `06-jobtable-regression.spec.ts`
  guards this (distinct rows + valid links + click navigates to a 200 job view).
  It is written to FAIL on the old 1.0 assets.
- The job table pins the harness-internal log row into the table's `<thead>`
  (`place_row` does `state.header.after(row)`), so a `table.job_table > tbody >
  tr` count omits it; the regression spec counts job rows table-wide by their
  rendered `job_try_id`.

## Screenshot baselines

`*-snapshots/` directories hold the screenshot baselines. They are
platform/browser specific; if you run on a different OS/Chromium build,
regenerate with `--update-snapshots`. The screenshot assertion uses a tolerant
`maxDiffPixelRatio` so minor antialiasing differences do not fail the run.
