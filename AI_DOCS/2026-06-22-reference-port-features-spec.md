# Reference-port features — ticket-detail spec (working doc)

**Status:** WORKING DOC. Accumulates the resolved ticket-level detail for the
reference-survey features the user selected to port. Once all items are discussed, this
becomes real entries in `ARCHITECTURE.md` + `TODO_STEPS.md` + `TODO_TASKS.md` (then this
doc is the provenance record). We are populating ticket detail now, **not** implementing.

Source: the reference-feature survey (workflow `wkg6c1k4p`). Selected items (user):
**#1 directives, #3 retry contract, #5 job_try columns, #10 OS-limit resources,
#11 parse_count_or_pct, #13 ResetTerm, #15 list/ping**. (#3/#5 are DB-schema and may fold
into the DB spec rather than stand-alone tickets — pending Q3.3.)

Discussed one at a time; resolutions recorded below as each is settled.

---

## Item 1 — structured directives parser — **RESOLVED**

**Current state:** `App::Yath2::TestFile::_scan` inline-scans `HARNESS-…` lines into a
`_headers` hash (category/stage/duration/min_slots/max_slots/retry/retry_isolated/timeout/
`NO-<feature>`/conflicts) via a split-based if/elsif loop. No block form, quoting, sigils,
nested keys, or reuse. No `Directives` module exists.

**Resolution:**
- **New `Test2::Harness2::Util::Directives`** — a pure, field-agnostic **`HARNESS2:` grammar
  parser**, ported from `reference/harness_service/lib/Test2/Harness2/Util/Directives.pm`
  (431 lines; richer — multi-comment-leader `['#','//']`). Grammar: block form
  `key { … key }`, boolean sigils `@on/@off/@yes/@no/@true/@false/@default`, dotted keys
  folded into a nested subtree (`retry.isolated`, `timeout.event`, `feature.*`, `meta.*`),
  double-quoted values w/ escapes, line-numbered `croak`, collision + unterminated
  detection. Bring **old3's unit test** (`reference/old3/t/AI/unit/Harness2/Util/Directives.t`).
- **Separate compat module** (e.g. `…::Directives::Legacy`) — parses the 1.0 `HARNESS-…`
  lines and **converts them to the new internal representation** (the same nested hash the
  new grammar emits).
- **Precedence (decided):** if a file contains **any** `HARNESS2:` directive → parse with
  the new grammar and **ignore all legacy `HARNESS-`** (newer wins; a mixed file just means
  the author shipped both, we use ours). If a file has **no** `HARNESS2:` directive → run
  the compat parser over its `HARNESS-` lines. Either path yields the new internal
  representation.
- **Producer:** replace `TestFile::_scan` with: detect-and-parse (new or compat) →
  `_apply_directives` maps the nested hash onto harness fields (port the harness_service
  `App/Yath2/TestFile.pm::_apply_directives` mapping, lines 133-345).
- **Persisted field shapes (DB note):** free-form `meta.*` / `feature.*` nested subtrees →
  the run / job_try **`fields` JSON columns** (DB-spec decision 4), nesting preserved; the
  structural directives (`retry`/`timeout`/`category`/`duration`/`stage`/`conflicts`/slots)
  → dedicated job columns or the job params JSON. Directive-derived field shapes feed the
  schema, so settle them with the DB schema (before the logger). No schema-breaking change
  forced by the parser itself.

**Subsystem:** directives. **DB impact:** minor (persisted field shapes). **Effort:**
medium. **ARCHITECTURE:** new "Directives" subsection (§4.x). **TODO:** own chunk/ticket.

---

## Item 3 — retry recording contract — **RESOLVED** (folds into the DB schema work)

**NOT a scheduler port.** The reference (`dbix_quickorm/Scheduler.pm`) is a **DB-driven
scheduler** (DB = scheduler state: `next_job` on `passed IS NULL`, `start_try`/`finish_try`
re-issue on `should_retry && max_ord < retry_limit+1`). We do **not** adopt that — our
runner schedules **in-memory** (`Runner/State.pm`: `retry_task` re-dispatches with
`is_try++` on a real failure; `requeue_task` re-dispatches without consuming a try),
DB-free (DB-spec decision 2c), and the separate-process/DB-driven retry was deliberately
removed (`Role/Scheduler.pm:97`). The runner keeps owning *when* to retry.

**What we take = the recording contract + finalize rule (Q3.2 = A, record-only):**
- The **logger** records each try as a **`job_tries` row** keyed by `try_ord` (= the
  runner's `is_try`, **1-based** per R10).
- A job is **resolved** when its tries are done; **`jobs.passed` = folded "any try
  passed."**
- **`should_retry` is runtime-only — NOT a persisted column.** `retry_limit` is **input**,
  lives in the job's **params JSON**. (Optional cheap non-load-bearing visibility flags —
  e.g. "retry_isolated applied" — can be added later if wanted; not needed now.)

**Organization (Q3.3 = FOLD):** no new ticket/chunk. Folds into the existing DB work:
- DB spec §4/§5: add the retry-recording + `jobs.passed = any-try-passed` rule.
- ARCHITECTURE §4.6.1: extend the schema-model subsection with the finalize rule.
- TODO ticket **#46** (schema): the `job_tries`/`jobs` column set + finalize rule; ticket
  **#50** (logger): "fold `jobs.passed` from tries; one `job_tries` row per `is_try`."
  Labeled `Steps:` bullets cite "survey #3".

**Subsystem:** scheduler/db-schema (recording). **DB impact:** significant (folds into
schema). **Effort:** medium. Pairs with **#5** (verdict columns) — together they define the
`job_tries`/`jobs` recording shape.

---

## Item 5 — job_try verdict columns — **RESOLVED** (folds into the DB schema work)

Reconcile the new `job_tries` column set from old4 (`DB/JobTry.pm`) + the t2clib Auditor
`final_state` + the DB-spec sketch. The Auditor produces `pass_count`/`fail_count`/
`assertion_count`/`top_level_subtests`/`subtests[]`; the subtest pass/fail split is
**derived** from `subtests[]`.

**Final `job_tries` folded-verdict columns (Q5.1/Q5.2 agreed):**
- `try_ord` — 1-based (R10)
- **`result`** — tri-state verdict (null = in-flight / true = pass / false = fail) — the
  top-line "did this try pass" (distinct from the counts)
- `assertion_count`, `pass_count`, `fail_count` (assertions)
- `subtests` (= top_level_subtests count), **`subtests_passed`**, **`subtests_failed`**
  (the split, derived from the auditor's `subtests[]`)
- `status` enum, `exit_code`, `started`/`finished` (+ `duration`)
- `params` JSON, **`fields` JSON** (directives, #1)
- **DROP `stdout`/`stderr` columns (Q5.3)** — read on demand from the artifact blob (R6);
  no duplicating large output already in the blob.
- *Naming cleanup:* counts are `pass_count`/`fail_count` (NOT old4's `passed`/`failed`,
  which collide with the `result` verdict bool).

**jobs:** `passed` = folded "any try passed" (from #3).

**Organization:** FOLD (with #3) — amend DB spec §4/§5 + ARCHITECTURE §4.6.1 + tickets #46
(column set) / #50 (logger writes the folded row). Provenance: "survey #5".

**Subsystem:** db-schema. **DB impact:** significant. **Effort:** small.

---

## Item 10 — OS-limit throttle resources — **RESOLVED**

Port three resources from old3 into `Test2::Harness2::Runner::Resource::` on the current
`Role::Resource` contract (`available`/`assign` + `tick`/`refresh`/`job_limiter*`/`record`):
- **PipeLimits** — bound concurrency by pipe FDs / kernel pipe-ring pages
  (`/proc/sys/fs/pipe-*`); knobs `pipes_per_test`/`pipes_per_service`/`service_count`/
  `pages_per_pipe`/`headroom`. (needs `parse_count_or_pct`, #11)
- **UnixLimits** — cap by RLIMIT `nproc`/`nofile`/`as` (count or %-of-limit).
  (needs `parse_count_or_pct` + `parse_size_or_pct`)
- **Disk** — throttle/abort on low free space per mount.

**Decisions:**
- **(Q10.1) All three.** Rationale: pipe-heavy architecture (sockets + SCM_RIGHTS fd-pass +
  collectors everywhere) → pipe-page/`nofile` exhaustion under high `-j` is a real
  unthrottled failure mode; artifact-blob writes make disk pressure likely.
- **(Q10.2 = B) DB-IMPACTING: un-defer the `resources` + `resource_types` tables.** These
  resources persist resource-state rows NOW, so the deferred (d4) `resources`/
  `resource_types` tables come **back into the DB schema scope**. Folds into the DB work:
  amend DB-spec d4 (un-defer resources/resource_types), tickets **#46/#47** (add the two
  tables), **#50** (logger records resource-state rows). Benefits all resources (CPU/Memory/
  SystemLoad too), not just the OS-limit ones.
- **(Q10.3) `Filesys::Df` = optional dep**, lazy-required with an actionable error only when
  a disk-% limit is requested (R11 pattern); absolute free-space limits work without it.

**System-load sampler note (user):** chunk 7's system-load service already provides a
constant, up-to-date rounded **CPU** (and likely **memory**) snapshot the CPU/Memory
resources consume — don't re-sample those. *Adaptation lean (settle at impl):* extend the
sampler to also carry the pipe/rlimit/disk metrics so **all** resources read one shared
up-to-date snapshot (one tick), rather than each resource sampling independently. Reconcile
old3's `Utilizer` role + `utilize_percent` with the current `Role::Resource` (+ chunk-7
throttling) during the port.

**Subsystem:** resource. **DB impact:** significant (un-defers resources/resource_types).
**Effort:** medium. **Depends:** #11. **ARCHITECTURE:** resources subsection + the §4.6
resources-table un-defer. **TODO:** own ticket(s) for the resources + a fold into #46/#47/#50
for the table.

---

## Item 11 — Units helpers `parse_count_or_pct` + `parse_duration` — **RESOLVED**

Port **both** `parse_count_or_pct` (`"NUMBER"` → count / `"NUMBER%"` → pct; built on the
existing `parse_quantity`) and `parse_duration` from `reference/old3/.../Util/Units.pm`
into `lib/Test2/Harness2/Util/Units.pm`, in current's signature style
(`sub parse_count_or_pct ($raw, %opts)`). Add to `@EXPORT_OK`.

**Why both:** `parse_count_or_pct` is required by the OS-limit resources (#10);
`parse_duration` is cheap + useful for the `timeout`/`duration` directives (#1).

**Subsystem:** options/util. **DB impact:** none. **Effort:** small. **Blocks:** #10.
**ARCHITECTURE:** none (util helper; mention under directives/resources). **TODO:** own
small ticket (or a sub-step of #10's resource ticket).

---

## Item 13 — ResetTerm renderer — **RESOLVED**

Port old3's `ResetTerm` (16 lines): a no-op `render_event` renderer whose `finish` prints a
terminal reset (`\e[0m…`) **only when `-t STDOUT`**, undoing color/mode left by misbehaving
tests. New: `App::Yath2::Renderer::ResetTerm`.

**Adaptation (mechanical):** parent `Test2::Harness2::Renderer` (not old3's
`App::Yath2::Renderer`); `Object::HashBase` → `Test2::Harness2::Util::HashBase`; **drop
`desired_filters`** (no Filter machinery); runs **last** via current's renderer ordering;
use a correct reset escape (`\e[0m` for attributes; optionally re-enable line-wrap).

**Decision (Q13.1):** **default-on when STDOUT is a TTY** — auto-added to the renderer list
(no-op otherwise); a free safety net for tests that leave the shell in a weird state.

**Subsystem:** renderer. **DB impact:** none. **Effort:** small. **ARCHITECTURE:** mention
in the renderers section (default-on-when-TTY). **TODO:** own small ticket.

---

## Item 15 — `yath list` + `yath ping` commands — **RESOLVED**

Two new commands under `App::Yath2::Command`, adapted from `reference/pre_ai_2.0`
(`list.pm`/`ping.pm`) to the current Discovery + `App::Yath2::Client`:
- **`yath list`** — **glob the well-known symlink dir** (`/{tmpdir}/.*-yath-runner.sock`),
  follow each → liveness-connect → print all **live persistent** runners grouped; clean
  dangling symlinks. (Current Discovery is single-symlink-per-prefix with a one-resolve
  `find()`; `list` adds the enumerate-all path.)
- **`yath ping`** — loop on `App::Yath2::Client`: round-trip `ping()`, print latency, sleep;
  add a `Client->ping()` request if the client lacks one.

**Decision (Q15.1 = a):** **persistent-only.** One-off `yath test` runs have a workdir
`runner.socket` but no well-known marker, so `list` won't show them — documented limitation;
one-off discovery is a separate, larger change (would require one-off runs to publish a
discoverable marker), not in scope.

**Subsystem:** cli. **DB impact:** none. **Effort:** small. **ARCHITECTURE:** mention under
discovery/commands. **TODO:** own small ticket (list + ping).

---

## All 7 items resolved (2026-06-22). Next: write real ARCHITECTURE + TODO entries.

| Item | Disposition | DB-impact | Lands as |
|---|---|---|---|
| #1 directives | new grammar parser + legacy compat; HARNESS2 wins (silent); parse-error→synthetic failure; meta/feature persistence DEFERRED (E5) | **none** (structural fields already flow) | new ARCH §; own ticket |
| #3 retry recording | record-only; runner owns retry; jobs.passed folded | significant | **FOLD** into DB schema (#46/#50, §4.6.1) |
| #5 job_try columns | result tri-state + counts + subtest split; drop stdout/stderr | significant | **FOLD** into DB schema (#46/#50, §4.6.1) |
| #10 OS-limit resources | **UnixLimits + Disk only (PipeLimits dropped, E3)**; runtime throttling; resource tables RE-DEFERRED (E4); optional Filesys::Df/BSD::Resource | **none** | new ARCH §; own ticket |
| #11 Units helpers | parse_count_or_pct + parse_duration | none | small ticket (blocks #10) |
| #13 ResetTerm | default-on when TTY; fire on abnormal exit | none | small ticket |
| #15 list/ping | persistent-only list (discovery enum API) + ping (needs runner handler) | none | small ticket |

**DB-impacting (settle with the DB schema before DB-1 build):** only **#3 + #5**
(`job_tries`/`jobs` verdict columns + retry-recording fold). #1 and #10 are **no longer
DB-impacting** (E4 re-defer, E5 defer).

---

## Review refinements (gemini + gpt, 2026-06-22) — TRIVIAL/OBVIOUS, applied

These enrich ticket detail; no behavior decision (the significant ones are escalated
separately).

**Item 1 (directives):**
- **Preserve the O(1) header scan** [G1]: the new parser must **early-terminate** at the
  first real code line outside an open block (like current `_scan`'s `last unless …`), plus
  a safety line-limit ceiling (~500) — don't regex the whole file.
- **Only `App::Yath2::TestFile`** (the file-reading object) gets the scanner/compat [GPT1].
  `Test2::Harness2::TestFile` stays **file-free / state-only** (post chunk-14 split); it
  gains accessors only if the task payload gains already-computed fields — it never loads
  the parser or reads files.

**Item 5 / DB fold:**
- Use **`parameters`** JSON (align to the DB spec; not `params`) [GPT4].
- **Fold rules:** `jobs.passed` = any-try-passed (resolved true); `jobs.failed` = resolved
  && !passed; `runs.passed/failed/retried` = aggregate over resolved jobs [GPT4].
- (drop stdout/stderr + the result/assertion_count/subtest-split must be written into the DB
  spec's `job_tries` shape when folding — already decided Q5.)

**Item 3 / logger:** ticket **#50 depends on #49** (1-based producer) [GPT5].

**Item 10 (OS resources):**
- **`is_supported` hook** [G4]: gracefully deactivate (no constraints / infinite) + verbose
  log on unsupported OS (`/proc` absent on macOS/BSD/Windows); never crash.
- **RLIMIT querying** [G5]: Linux reads `/proc` (no dep); off-Linux RLIMIT support →
  **optional `BSD::Resource`** (Suggests, lazy-require, disable+warn if missing *and*
  requested).
- **`Disk` dep correction** [GPT8]: `Filesys::Df` is required when the **`Disk` resource is
  used at all** (both absolute and percent thresholds need free/total bytes; no portable
  core statvfs) — optional dep, lazy-required when `Disk` is requested, actionable error if
  missing. *(Supersedes #10.3's "only for percent".)*

**Item 11:** scope **`parse_duration` to timeout values** (`timeout.event`/`timeout.postexit`
→ seconds) [GPT9]; the `duration short|medium|long` directive stays a **scheduling label**,
NOT parsed as seconds.

**Item 13 (ResetTerm):**
- Class `App::Yath2::Renderer::ResetTerm`, **default-injected LAST** in the renderer `'@'`
  list (current has no `weight` sorting — list order) [GPT10]; standard escapes `\e[0m` +
  `\e[?25h` (cursor), avoid `\e[=l`.
- **Fire on abnormal exit** [G6]: ensure the harness abort/teardown path calls renderer
  `finish()`, plus an `END`-block fallback in ResetTerm, so the reset prints on Ctrl-C /
  panic — *not* a renderer-owned signal handler (the harness owns signals).

**Item 15 (list/ping):**
- **`list` = a discovery enumeration API**, not a naive glob [GPT11]: add
  `Discovery->list`/`find_runner_links` that **reuses `find_runner_link`'s dir/name rules**
  (persist_file / persist_dir / `YATH_PERSISTENCE_DIR` / cwd-walk / user+host+project
  basename); probe liveness; clean only links it owns.
- **Multi-user safety** [G7]: catch `EACCES`/`ECONNREFUSED` → show "inaccessible (other
  user)"; only clean dangling links owned by the **current UID**.
- **`ping` needs runner-side support** [GPT12]: add a no-side-effect **ping request handler**
  on the runner service (`{ok=>1, pid, stamp}`), expose via
  `Test2::Harness2::Runner::Client` / `App::Yath2::Client`, then build the command loop.

---

## Escalation resolutions (2026-06-22) — significant review findings

- **E1 (parse errors) = A.** The new parser `croak`s; **`App::Yath2::TestFile` catches**,
  marks that file invalid, and **queueing it emits a harness-visible test failure** — the
  run continues, the broken file fails. (Tests: bad quote, mismatched block, mixed good/bad
  files in one run.)
- **E2 (mixed mode) = B (silent).** When a file has any `HARNESS2:`, legacy `HARNESS-` is
  ignored with **no warning** (as originally decided). No mixed-mode diagnostic.
- **E3 (OS-limit metric source) = DROP `PipeLimits` for now.** Item 10 keeps only
  **`UnixLimits` + `Disk`**. Volatile/process-local metrics (e.g. `nofile`, `/proc/self/fd`)
  are read **in-resource, runner-local** at assign time — **not** via the system-load
  sampler (reading `/proc/self` in the sampler would count the *sampler's* FDs, and a 0.2s
  snapshot races burst spawns). **The "extend the sampler to carry pipe/rlimit/disk" lean is
  dropped** — `UnixLimits`/`Disk` read their own metrics on tick; static kernel caps read
  once. (CPU/Memory keep using the sampler snapshot as before.)
- **E4 (resource tables) = RE-DEFER.** Reverts 10.2 to **A**: the `resources`/
  `resource_types` tables **stay deferred** (d4). Item 10 is now **pure runtime throttling
  with NO DB impact**; persistence rides the later deferred resources-table work.
- **E5 (directive meta/feature persistence) = DEFER.** Do **not** persist arbitrary
  `meta.*`/`feature.*` now. Only the **structural** directive fields
  (retry/timeout/category/duration/stage/conflicts/slots) flow to the task/DB (they already
  do). The `meta.*`/`feature.*` durable path (task payload + snapshot + logger plumbing) is
  a **future spec**. So Item 1 now has **no new DB-schema impact** (structural fields only).

### Net effect on the items
- **#1 directives:** parse-error = catch+synthetic-failure (E1); mixed = silent (E2);
  meta/feature persistence **deferred** (E5) → **no new DB impact**; only structural fields
  flow (already wired). Still a real subsystem (new grammar + legacy compat).
- **#10 resources:** **drop `PipeLimits`**; keep `UnixLimits` + `Disk` (read metrics
  in-resource, runner-local); resource tables **re-deferred** → **no DB impact**. Needs
  `parse_count_or_pct` (#11) + optional `Filesys::Df`/`BSD::Resource` + `is_supported`.

### Revised DB-impacting set (settle with the DB schema before DB-1 build)
**Only #3 + #5** (the `job_tries`/`jobs` verdict columns + retry-recording fold). #1 and #10
are **no longer DB-impacting**.
