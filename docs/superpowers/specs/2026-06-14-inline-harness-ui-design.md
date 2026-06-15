# Inline Test2-Harness-UI into Test2-Harness2 (DBIx::Class port) — Design

**Date:** 2026-06-14
**Branch/worktree:** `harness-ui-inline` (off `2.0d`)
**Status:** Approved (user waived spec/plan review; autonomous execution)

## Goal

Inline the Test2-Harness web UI into the `Test2-Harness2` distribution, following
the **pre_ai_2.0 module layout and naming** (not the 1.0 layout), converted to
the `App::Yath2::*` / `Test2::Harness2::*` namespaces, retargeted to the event
facets our current branch emits, with options on `Getopt::Yath`, and with a real
test suite (Perl + JS/CSS) where there was essentially none.

This is **chunk 1 of three**:
1. **(this spec)** Inline the UI on **DBIx::Class**, faithful to pre_ai structure + new tests.
2. (next spec) Convert the UI schema layer to **DBIx::QuickORM**, verified by chunk-1's ORM-agnostic tests.
3. (later) Schema-changing UI features.

## Sources

- **Structure / naming / options / web+schema design → `reference/pre_ai_2.0`** (preferred).
  Inlined there as `App::Yath::Server*`, `App::Yath::Schema*`, `App::Yath::Command::{server,db/*,client/*}`,
  `App::Yath::Options::{DB,WebServer,Server,WebClient,Publish}`, `App::Yath::Plugin::DB`,
  `App::Yath::Renderer::{DB,Server}`. Options already on Getopt::Yath.
- **Web assets (`share/{templates,js,css,img,schema}`), `demo/`, `share/psgi/*` → 1.0 `~/projects/Test2/Test2-Harness-UI`**
  (the pre_ai snapshot omitted `share/`). Reconcile 1.0 asset filenames to the names pre_ai's controllers reference.
- **Event/facet shapes → our current 2.0d** (closer to 1.0's expectations, updated for our renames).

## Target layout (in this dist)

```
lib/App/Yath2/Server.pm                      # Plack::Runner orchestrator; ephemeral DB; importers; daemon
lib/App/Yath2/Server/Plack.pm                # PSGI app, Router::Simple (~90 routes), static mounts
lib/App/Yath2/Server/{Request,Response,Controller}.pm
lib/App/Yath2/Server/Controller/*.pm         # 22: View Stream Run RunField Job JobTryField Events Query
                                             #     Lookup Recent Project Durations Coverage Files ReRun
                                             #     Resources Interactions Binary Download Upload Sweeper User
lib/App/Yath2/Server/Util/Errors.pm
lib/App/Yath2/Schema.pm
lib/App/Yath2/Schema/{ResultBase,ResultSet}.pm
lib/App/Yath2/Schema/Result/<T>.pm           # 29 stub dispatchers (require Driver + Overlay)
lib/App/Yath2/Schema/<Driver>/<T>.pm         # generated; drivers: SQLite MySQL MariaDB Percona PostgreSQL
lib/App/Yath2/Schema/Overlay/<T>.pm          # 29 hand-written (relationships, inflation, methods)
lib/App/Yath2/Schema/{Config,Util,Importer,RunProcessor,Sync,Sweeper,Queries,ImportModes,DateTimeFormat}.pm
lib/App/Yath2/Command/server.pm
lib/App/Yath2/Command/db.pm
lib/App/Yath2/Command/db/{importer,publish,recent,sweeper,sync}.pm
lib/App/Yath2/Command/client/{publish,recent}.pm
lib/App/Yath2/Options/{DB,WebServer,Server,WebClient,Publish}.pm
lib/App/Yath2/Plugin/DB.pm
lib/App/Yath2/Renderer/{DB,Server}.pm
lib/Test2/EventFacet/Binary.pm               # custom list facet (extends real Test2::EventFacet) — keep name
share/{templates,js,css,img,schema}          # from 1.0 share/, reconciled to pre_ai asset names
share/psgi/{demo,test}.psgi
demo/                                         # sample logs + launchers (pre_ai structure)
author_tools/regen_schema.pl
js-tests/                                     # Playwright project (own package.json)
```

29 schema tables (pre_ai set): ApiKey Binary Config Coverage CoverageManager Email
EmailVerificationCode Event Host Job JobTry JobTryField LogFile Permission PrimaryEmail
Project Reporting Resource ResourceType Run RunField Session SessionHost SourceFile
SourceSub Sweep TestFile User Version.

## Decisions (approved)

- **ORM:** DBIx::Class now (3-layer Result/Driver/Overlay + `regen_schema.pl`); QuickORM is chunk 2.
- **Scope:** full pre_ai feature set (server + ephemeral DB + db/* + client/* + Plugin/DB + Renderer/DB|Server + all 5 drivers).
- **DB default for ephemeral + tests:** **SQLite** (zero-setup → CI + Playwright runnable without Postgres). All 5 drivers supported.
- **Email/auth/User:** ported for parity; only active in multi-user mode (not ephemeral/single_user).
- **Tests:** Perl HTTP smoke + Playwright (JS/CSS), under `js-tests/` with its own package.json.
- **ORM isolation:** controllers/RunProcessor go through Schema/ResultSet/Overlay, not scattered raw DBIC, so chunk-2 swap is localized.

## Conversion rules

- `App::Yath::*` → `App::Yath2::*`; `Test2::Harness::*` → `Test2::Harness2::*`.
- Fix embedded strings, not just `package` lines: `require "App/Yath2/Schema/${LOADED}/..."`,
  `File::ShareDir::dist_dir('Test2-Harness2')`, `share_dir`/`share_file` paths.
- Clean stale `Test2-Harness-UI` POD repo refs and `FIXME/POD NEEDS AUDIT` markers noted in pre_ai.
- Keep `Test2::EventFacet::Binary` name (facet identity).

## Facet alignment (highest risk)

`RunProcessor` (the ~1100-LoC importer) reads facets directly. Our 2.0d emits (collector-swap merged):
`harness_run, harness_settings, harness_job, harness_job_queued, harness_job_start, harness_job_launch,
harness_job_end, harness_job_exit, harness_job_fields, harness_final, harness_final_state,
harness_process_exit, harness_state_transition, harness_watcher, harness_job_watcher, harness_event`,
plus core Test2 facets (`trace, hubs[0].nested, parent.children, assert.pass, amnesty, errors, info, meta, times`).

**Required step before/while porting RunProcessor:** run a real `yath test` on 2.0d, capture a
`.jsonl` log, diff the actual event/facet shapes against what the ported RunProcessor expects, adapt
the importer, and write unit tests that lock the mapping (input log fixture → expected DB rows). Pay
special attention to `harness_job_end.times.totals.total`, the `harness_run_fields` vs `fields`
fallback, subtest nesting via `hubs[0].nested` + `parent.children`, and any 1.0→2.0 facet renames.

## Web layer

Plack + Router::Simple + Text::Xslate + Starman (default launcher, configurable). Static mounts
`/js /css /img /favicon.ico` via `Plack::App::{Directory,File}`. Controllers are HashBase objects
subclassing `App::Yath2::Server::Controller`; each `handle()` builds a response, registers
`add_css`/`add_js`, renders a `.tx` template from `share_dir('templates')`.

## Options

Port the Getopt::Yath option groups from pre_ai: `DB` (group/prefix `db`), `WebServer` (group
`webserver`, includes DB), `Server` (group `server`), `WebClient` (group `webclient`), `Publish`
(group/prefix `publish`). Attach to commands per pre_ai's `include_options` map (server: DB+WebServer+Server;
db: DB+Server; db/importer: DB; db/publish: DB+Publish; db/sweeper: DB; client/publish: WebClient+Publish[mode];
client/recent: WebClient; Plugin/DB: DB+Publish). Preserve `accepts_dot_args`/`set_dot_args` →
`webserver.launcher_args`. Carry the enhancements: `--ephemeral[=Driver]` (Auto driver), `--shell`,
`--single_user`/`--single_run`/`--no_upload`, `port_command`, `workers` default = core count,
`db config` pluggable module, `from_env_vars`/`allowed_values`/`autofill`.

## Database

DBIx::Class, 5 drivers. `share/schema/<Driver>.sql` DDL = source of truth. `author_tools/regen_schema.pl`
spins each DB via `DBIx::QuickDB` + `make_schema_at` (Schema::Loader) to regenerate per-driver Result
classes; Overlays are hand-written and survive regen. Ephemeral DB via `DBIx::QuickDB->build_db` loading
the matching `.sql`. Percona binary-UUID handling preserved.

## Tests (the new safety net — ORM-agnostic where possible)

- **Perl unit:** `Schema::Util` durations; **`RunProcessor` facet→row mapping** (real coverage from a
  captured log fixture); key Overlay methods; option parsing for each Options module.
- **Perl HTTP smoke:** spin an ephemeral **SQLite** server, assert routes/status, served HTML/JS/CSS
  presence + headers, and JSON API response shapes for the main controllers.
- **Playwright** (`js-tests/`, own package.json): ephemeral SQLite server loaded with a `demo/` sample
  log; drive main views — runtable/jobtable/eventtable render, DataTables works, chart renders,
  interactions, subtest expand; CSS rendering/layout sanity. Wired as a dev/author test.

## Dependencies to add (dist.ini)

Web: Plack, Router::Simple, Text::Xslate, Starman (suggest). DB: DBIx::Class (+Schema::Loader,
InflateColumn::DateTime, InflateColumn::Serializer(::JSON), Tree::AdjacencyList, UUIDColumns,
Helper::ResultSet::RemoveColumns), DBI, DBIx::QuickDB, DBD::SQLite + DateTime::Format::SQLite;
DBD::Pg/mysql etc. as suggests. HTTP client: LWP::UserAgent. Auth/email: Crypt::Eksblowfish::Bcrypt,
Email::Sender::Simple, Email::Simple(::Creator). Util: DateTime, Time::Elapsed, Statistics::Basic,
Scope::Guard, System::Info (suggest). Test-only: HTTP::Tiny(::UNIX). JS: Playwright (dev, outside dist).

## Out of scope (this chunk)

- QuickORM conversion (chunk 2).
- Schema redesign / new UI features (chunk 3).
- Dockerfile modernization (port as-is, mark stale).

## Non-obvious risks

1. Facet mapping (above) — silent importer breakage; mitigated by the fixture→rows unit test.
2. Asset name reconciliation between 1.0 `share/` and pre_ai controller `add_js`/`add_css` calls.
3. ~145 generated per-driver classes: regenerate via the tool after rename rather than hand-editing.
4. SQLite feature parity (e.g. `can_store_null_character`, UUID/date formats) — pre_ai already
   carries per-driver predicates; preserve them.
</content>
