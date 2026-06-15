import { test, expect, Page } from '@playwright/test';
import { waitForRunRows, runIdFromTable } from './helpers';

// REGRESSION SPEC for the jobtable.js field-name bug.
//
// Background: the inlined UI's share/ assets were originally copied from the OLD
// 1.0 UI, but the inlined server emits the pre_ai 2.0 data model. The 1.0
// jobtable.js used `item.job_key` both as the per-row DOM id and as the
// "Open Job" link target, but the server never emits `job_key`. Two visible
// breakages resulted:
//
//   1. Every job row got `id=undefined`, so each new job row REPLACED the
//      previous one (FieldTable._render_item does replaceWith when a row with
//      the same id already exists). The job table collapsed to a single row
//      instead of listing every job.
//   2. The "Open Job" link became `view/<run>/undefined`, which 404/500s on
//      click.
//
// The fix swapped jobtable.js / view.js to the pre_ai contract:
//   - row id  = item.job_try_id (unique per job try)
//   - open link = view/<run_uuid>/<job_uuid>/<job_try_ord>
//     (view.js injects run_uuid onto each job item from the streamed run)
//
// These assertions are written so they would have FAILED on the old 1.0 assets:
//   - distinct-rows  -> would have collapsed to 1 row
//   - no-`undefined` -> the href literally contained "undefined"
//   - click-succeeds -> the undefined URL 404/500'd
//
// The configured demo log (demo/simple-fail.jsonl.bz2) has multiple jobs:
// the harness-internal log, a passing job (simple.t) and a failing job
// (fail.t) -> three DISTINCT job rows.

const JOB_ROWS = '#jobs table.job_table > tbody > tr';
const OPEN_JOB = `${JOB_ROWS} td.tools a[title="Open Job"]`;

// Read the run-scoped JSONL stream (same data the front-end consumes) and count
// the distinct job rows the table is expected to render, keyed by job_try_id
// exactly as view.js keys them. This makes the "correct number of rows"
// assertion self-checking against the real run rather than a hard-coded number.
async function expectedJobTryIds(page: Page, runId: string): Promise<Set<string>> {
  const res = await page.request.get(
    `/stream/${runId}?content-type=application/x-jsonl`,
    { timeout: 30_000 },
  );
  expect(res.ok()).toBeTruthy();
  const ids = new Set<string>();
  for (const line of (await res.text()).split('\n')) {
    if (!line.trim()) continue;
    const item = JSON.parse(line);
    if (item.type === 'job' && item.data && item.data.job_try_id != null) {
      ids.add(String(item.data.job_try_id));
    }
  }
  expect(ids.size).toBeGreaterThan(1); // a multi-job run, by construction
  return ids;
}

async function openRun(page: Page): Promise<string> {
  await page.goto('/');
  await waitForRunRows(page);
  const runId = await runIdFromTable(page);
  await page.goto(`/view/${runId}`);
  await expect
    .poll(async () => page.locator(JOB_ROWS).count(), { timeout: 30_000 })
    .toBeGreaterThan(0);
  return runId;
}

test.describe('jobtable regression: rows are distinct and links are valid', () => {
  test('the job table lists every distinct job row (no collapse/replace)', async ({ page }) => {
    const runId = await openRun(page);
    const expected = await expectedJobTryIds(page, runId);

    // FieldTable sets each data row's <tr id="..."> to the id passed to
    // render_item (= item.job_try_id). Count every job-table data row by its
    // rendered id. NOTE: place_row pins the harness_out row into the table's
    // <thead> (state.header.after(row)), so we look table-wide, not just the
    // tbody, to catch all job rows. We key by the stream's job_try_id set so a
    // header/marker <tr> (no matching id) is naturally excluded.
    //
    // On the OLD 1.0 assets every row was rendered with id=undefined, so each
    // new job's row replaceWith()'d the previous one -> the set collapses to a
    // single id ("undefined"). This assertion would have failed there.
    const renderedIds = await page
      .locator('#jobs table.job_table tr[id]')
      .evaluateAll((trs) => trs.map((tr) => (tr as HTMLElement).id));

    const renderedJobIds = new Set(renderedIds.filter((id) => expected.has(id)));

    // Exactly the distinct stream job_try_ids are present as rows - one row each,
    // none collapsed away, none "undefined".
    expect(renderedIds).not.toContain('undefined');
    expect(renderedJobIds).toEqual(expected);
    expect(renderedJobIds.size).toBe(expected.size);

    // And the distinct test-file names are all present (fail.t, simple.t, the
    // harness log) -> visually confirms rows were not replaced by one another.
    const names = await page
      .locator('#jobs table.job_table td.job_name')
      .evaluateAll((tds) => tds.map((td) => (td.textContent || '').trim()));
    const distinctNames = new Set(names.filter((n) => n.length > 0));
    expect(distinctNames.size).toBe(expected.size);
  });

  test('every "Open Job" link is a real run/job/try URL, never "undefined"', async ({ page }) => {
    await openRun(page);

    const links = page.locator(OPEN_JOB);
    await expect.poll(async () => links.count(), { timeout: 30_000 }).toBeGreaterThan(0);

    const hrefs = await links.evaluateAll((as) =>
      as.map((a) => (a as HTMLAnchorElement).getAttribute('href') || ''),
    );
    expect(hrefs.length).toBeGreaterThan(0);

    for (const href of hrefs) {
      // The old bug produced exactly this literal in the URL.
      expect(href).not.toContain('undefined');
      // Shape: view/<run-uuid-ish>/<job-uuid-ish>/<try-ordinal-digit>.
      // UUID-ish = hex+dash token (the pre_ai server emits upper/lower hyphenated
      // uuids), try ordinal = a bare integer.
      expect(href).toMatch(/view\/[0-9A-Za-z-]+\/[0-9A-Za-z-]+\/\d+$/);
    }
  });

  test('clicking a job row navigates to a job/events view that loads (HTTP 200)', async ({
    page,
  }) => {
    await openRun(page);

    // Pick the failing job's row link (fail.t) so the destination also renders
    // an events table. Fall back to the first non-harness job link otherwise.
    const failRowLink = page.locator(`${JOB_ROWS}.error_set td.tools a[title="Open Job"]`).first();
    const anyLink = page.locator(OPEN_JOB).first();
    const link = (await failRowLink.count()) ? failRowLink : anyLink;

    await expect(link).toBeVisible({ timeout: 30_000 });
    const href = await link.getAttribute('href');
    expect(href).not.toContain('undefined');

    // Verify the destination responds 200 (the old undefined URL 404/500'd)...
    const dest = new URL(href!, page.url()).toString();
    const resp = await page.request.get(dest, { timeout: 30_000 });
    expect(resp.status()).toBe(200);

    // ...and that actually clicking the link drives the browser there and the
    // job/events view renders (event rows appear, no error page).
    await Promise.all([
      page.waitForURL(/\/view\/[^/]+\/[^/]+/, { timeout: 30_000 }),
      link.click(),
    ]);

    // The per-job view streams events; the event table renders event_line rows.
    await expect
      .poll(async () => page.locator('#jobs_events tbody tr.event_line').count(), {
        timeout: 30_000,
      })
      .toBeGreaterThan(0);

    // Sanity: we're on a real job view, not a 404/500 error page.
    await expect(page.locator('#header h1')).toHaveText('Test2-Harness-UI');
  });
});
