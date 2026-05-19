# Gemini Review Notes for yath 2.0 Rewrite Docs

I have reviewed the `ARCHITECTURE.md`, `AGENTS.md`, `STYLE_GUIDE.md`, `PART_1_PLAN.md`, and `PART_2_PLAN.md` documents. Overall, the work is excellent and strictly follows the `new_plan` requirements while making sensible architectural improvements.

## Key Improvements & Observations

*   **Recorder-Centric DB Access:** The design choice to force all Collector/Auditor database writes through the `Recorder` is a significant improvement over the `new_plan` suggestion of direct SQL access. This maintains the viability of the `Files` recorder for testing without sacrificing the performance of raw SQL (which the `DB` recorder can still use).
*   **Explicit Workdir:** The introduction of a formal `Workdir` concept managed by the harness handle (§15 in `ARCHITECTURE.md`) provides a clean lifecycle for temporary event files and test-job directories.
*   **PID Tracking:** Adding `pid` columns to the `services` and `launchers` tables is a helpful addition that facilitates the `SIGUSR1` wake-up mechanism described in `new_plan`.
*   **Normalization of Runners/Instances:** The split between `instances` (stable environment info) and `runners` (specific execution runs) clarifies the `new_plan`'s somewhat ambiguous mentions of these two concepts.
*   **Strict Style Guide:** The addition of module (1000 LOC) and subroutine (75 LOC) size limits in `STYLE_GUIDE.md` is a proactive measure for long-term maintainability.

## Minor Notes & Clarifications

*   **Terminology:** `new_plan` uses the term "mixed-message-mode" for `Atomic::Pipe`, while `ARCHITECTURE.md` uses "mixed-data-mode". This is likely a synonym, but it's worth noting.
*   **Dist::Zilla:** `new_plan` mentioned referencing `dzil.ini` from `reference/old3` for dependencies. While `AGENTS.md` mentions copying utility code, it might be worth explicitly mentioning `dist.ini` as a reference for the distribution setup in Part 1 or Part 2.
*   **Unavailable-Action Path:** `ARCHITECTURE.md` §8.3 correctly captures the requirement for unavailable-action launches to go through the `Default` launcher, ensuring deterministic failure reporting.

## Actionable Review Points for the Next Agent

1.  **Stage 1 Questions:** Address the questions in `PART_1_PLAN.md` Stage 1 regarding naming and `EventEmitter` logic before proceeding.
2.  **Files Recorder Path:** Define the default write path for the `Files` recorder as per the question in Stage 3.
3.  **.t2h2 Filename:** Confirm the filename pattern as per the question in Stage 5.
4.  **Bulk Insert Strategy:** Decide on the use of `SQL::Abstract` vs. raw SQL for bulk inserts in Stage 5.

The documents are ready to serve as the foundation for the rewrite.
