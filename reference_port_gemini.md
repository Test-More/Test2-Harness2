# Reference-Port Features Review: Gaps & Architectural Considerations

This review analyzes the proposed reference-port features detailed in [2026-06-22-reference-port-features-spec.md](file:///home/exodist/projects/Test2/Test2-Harness/AI_DOCS/2026-06-22-reference-port-features-spec.md). It outlines critical risks, performance considerations, compatibility gaps, and security edge cases that must be addressed before implementing these features.

---

## 1. Critical Finding: Directives Parser File Scanning Performance

### Context
In **Item 1**, the spec proposes `Test2::Harness2::Util::Directives` as a parser for comment-like in-file directives (`HARNESS2:`). The reference implementation under `reference/harness_service/lib/Test2/Harness2/Util/Directives.pm` implements this using a `while` loop that reads and processes the entire file line-by-line via regex matching.

### The Issue
Test files and compiled/source files can easily span thousands or tens of thousands of lines. Running a regex matching loop over the entire contents of every test file during the discovery phase introduces a major CPU and I/O performance bottleneck. 

Legacy Yath (`App::Yath2::TestFile::_scan`) optimizes this by using a strict parser convention: it skips empty lines, processes shbangs/comments, and **breaks immediately** (`last unless ...`) upon encountering the first line of real code.

### Actionable Recommendation
*   **Enforce Early Termination:** Modify the `parse_fh` / `parse_line` loop to terminate scanning as soon as a non-comment, non-whitespace, non-shbang line of code is encountered outside of an active block. This preserves the legacy O(1) scanning performance for headers at the top of files.
*   **Fallback Depth Limit:** As a safeguard, specify a hard line-limit ceiling (e.g., 200 or 500 lines). If the scanner has read that many lines without finishing, it should terminate to avoid scanning massive files.

---

## 2. Critical Finding: Directives Parser Syntax Error Isolation

### Context
In **Item 1**, the proposed directives parser is designed to throw line-numbered syntax errors using `croak` when it encounters issues like mismatched blocks (`key { ...` at EOF), key collisions, or unknown sigils.

### The Issue
During run initialization or test discovery, `TestFile` will invoke the directives parser on all candidate files. If a single test file contains a syntax error in its directives (e.g., a typo in a block or a mismatched brace), a bare `croak` will propagate to the top level and **abort the entire test run** before any tests execute. This is too fragile; a single broken test comment should not take down the entire test run.

### Actionable Recommendation
*   **Catch and Isolate Scanner Errors:** In `TestFile::_scan`, wrap the `Directives` parsing logic in an `eval` block.
*   **Mark File Invalid:** If parsing fails, catch the exception, log/warn the error, and mark the specific `TestFile` object state as invalid (e.g., `$self->{invalid_directives} = $@`).
*   **Fail at Execution Time:** Let the scheduler or runner handle this test file by immediately emitting a synthetic failure event describing the directive syntax error, rather than crashing the harness process.

---

## 3. Architectural Finding: Stale Data & Race Conditions in OS-Limit Throttling

### Context
In **Item 10**, the spec proposes extending the system-load sampler service (from Chunk 7) to collect OS-limit metrics (like active pipe/FD counts and RLIMITs) so that the `PipeLimits` and `UnixLimits` resources can check a single, shared, change-gated snapshot on a 0.2s tick.

### The Issue
Throttling metrics like free disk space are slow-moving and safe to sample periodically. However, process-scoped limits like `nofile` (open file descriptors) are highly volatile and change instantly as workers are spawned. 

Because the runner can launch multiple concurrent jobs within a single millisecond, relying on a 0.2s change-gated snapshot will lead to severe race conditions: the runner will read a stale snapshot, assume it has plenty of FDs left, and spawn a burst of jobs that immediately exhausts the kernel limit, triggering unhandled `EMFILE` / `ENFILE` or pipeline pipe failures.

### Actionable Recommendation
*   **Local High-Precision Tracking:** For volatile constraints like `nofile` (file descriptor usage) and `pipes_per_service`, the runner should maintain a local, high-precision in-memory counter of active file descriptor slots allocated to running processes.
*   **Hybrid Evaluation:** Only use the sampler's cached snapshot for absolute kernel limits (such as `/proc/sys/fs/pipe-max-size` or maximum RLIMIT ceilings), but use the runner's exact in-memory slot/FD allocations to decide whether a new job can be spawned safely.

---

## 4. Portability Finding: Non-Linux OS Support for OS-Limit Resources

### Context
In **Item 10**, three resource throttle modules are proposed: `PipeLimits`, `UnixLimits`, and `Disk`. The spec notes that `PipeLimits` scans Linux-specific paths (`/proc/sys/fs/pipe-*`).

### The Issue
Yath runs on macOS (Darwin), FreeBSD, and Windows, where `/proc` is not available. If the `PipeLimits` resource tries to open `/proc` paths on macOS, it will fail, and if not handled, crash the runner. Throttling resources must fail-safe and degrade gracefully on unsupported operating systems.

### Actionable Recommendation
*   **Graceful Degradation Hook:** Force all OS-dependent resource modules to implement an `is_supported` method.
*   **Automatic Deactivation:** If `is_supported` returns false on the host OS, the resource should gracefully deactivate itself (e.g., return no constraints for `assign` or treat limits as infinite), print a verbose debug log message, and let the run proceed without crashing.

---

## 5. Dependency Finding: RLIMITs External Module Dependency (`BSD::Resource`)

### Context
In **Item 10**, `UnixLimits` is proposed to throttle concurrency by query-limits of RLIMIT `nproc`, `nofile`, and `as`.

### The Issue
Querying and manipulation of Unix RLIMITs in Perl requires the `BSD::Resource` CPAN module. However, `BSD::Resource` is not in the Perl core and compiles C code (which often fails on minimalistic environments or Windows). Making it a hard prerequisite violates Yath's goal of a zero-dependency runner core.

### Actionable Recommendation
*   **Treat as Optional Dependency:** Declare `BSD::Resource` as an optional dependency (e.g., `Suggests` in `dist.ini`).
*   **Lazy Load with Diagnostic:** In `UnixLimits`, lazy-load `BSD::Resource` using `eval "require BSD::Resource"`. If it is missing, disable RLIMIT-based throttling and output an actionable warning message to the user *only* if they requested Unix limits via CLI flags.

---

## 6. Robustness Finding: Abrupt Signal Interruptions for `ResetTerm`

### Context
In **Item 13**, the `ResetTerm` renderer is proposed to print terminal attribute reset sequences (`\e[0m`) in its `finish` method to clean up terminal states left by misbehaving tests.

### The Issue
If a test run is aborted abruptly (e.g., the user hits Ctrl-C / `SIGINT`, or the runner panics and exits), the normal lifecycle `finish` method of the renderer may never be called. The terminal will remain in a broken, corrupted, or cursor-hidden state, rendering the safety net useless when it is needed most (during aborted runs).

### Actionable Recommendation
*   **Register Signal/Exit Sanitizers:** Implement an `END` block or register a signal handler (`SIGINT`, `SIGTERM`) inside `ResetTerm` to ensure that if STDOUT is a TTY, the reset sequence is printed to the terminal during exit, regardless of how the process terminated.
*   **Standard Reset Sequence:** Ensure the sequence resets text attributes (`\e[0m`) and explicitly restores cursor visibility (`\e[?25h`). Avoid non-standard sequences like `\e[=l` which can have terminal-dependent side-effects.

---

## 7. Security & Multi-User Finding: Inaccessible Unix Domain Sockets in Shared `/tmp`

### Context
In **Item 15**, `yath list` is proposed to glob socket files under `{tmpdir}/.*-yath-runner.sock` and connect to each to verify runner liveness.

### The Issue
On shared Linux/Unix development servers, `/tmp` is shared among multiple users. Sockets created by User A are restricted by permissions and cannot be read/written by User B. If User B runs `yath list`, attempting to connect to User A's socket will fail with `Permission denied` (`EACCES`). If the connection logic does not handle this, the command will crash. Furthermore, User B's `yath list` must not attempt to clean up or delete dangling symlinks/sockets owned by User A.

### Actionable Recommendation
*   **Catch Connection Failures:** Wrap the socket connect attempt in an `eval` or a catch-block. If an `EACCES` or `ECONNREFUSED` occurs, handle it gracefully and show the runner as "Inaccessible (owned by another user)" instead of crashing.
*   **Check File Ownership:** Before attempting to clean up a dangling socket or symlink, verify the current user's UID matches the file's owner to avoid triggering permission errors during deletion.

---

## 8. Compatibility Finding: Mixed Precedence Warning for Directives

### Context
In **Item 1**, the spec states: "if a file contains **any** `HARNESS2:` directive → parse with the new grammar and **ignore all legacy `HARNESS-`**".

### The Issue
During transition, developers migrating large test suites may incrementally add new `HARNESS2:` directives to files while leaving older legacy `HARNESS-` directives in place. If the parser silently ignores all legacy directives the moment a single `HARNESS2:` is introduced, the test's behavior might silently change (e.g., a critical `HARNESS-DURATION-LONG` or `HARNESS-NO-PRELOAD` is ignored, leading to test timeouts or preload crashes).

### Actionable Recommendation
*   **Emit Mixed-Mode Warnings:** If the parser detects both `HARNESS2:` and legacy `HARNESS-` directives in the same file, it should emit a warning (either to stderr or as a non-fatal test warning facet) pointing out that legacy directives are being ignored due to the presence of `HARNESS2:`. This makes the migration path explicit and debuggable.
