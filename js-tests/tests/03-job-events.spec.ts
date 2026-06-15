import { test, expect, Page } from '@playwright/test';
import { waitForRunRows, runIdFromTable, waitForEventRows } from './helpers';

// Discover the *failing* job's uuid by reading the run-scoped JSONL stream
// directly (the same data the front-end consumes). This is just a convenient,
// deterministic way to single out the failing job (it carries data.fail) so the
// subtest/filter assertions below have a known target; the "Open Job" link
// itself is exercised (and asserted correct) by the regression spec in
// 06-jobtable-regression.spec.ts.
async function failingJobUuid(page: Page, runId: string): Promise<string> {
  const res = await page.request.get(
    `/stream/${runId}?content-type=application/x-jsonl`,
    { timeout: 30_000 },
  );
  expect(res.ok()).toBeTruthy();
  const body = await res.text();
  for (const line of body.split('\n')) {
    if (!line.trim()) continue;
    const item = JSON.parse(line);
    if (item.type === 'job' && item.data && item.data.fail && item.data.job_uuid) {
      return item.data.job_uuid;
    }
  }
  throw new Error('no failing job with a job_uuid found in run stream');
}

test.describe('job events and subtests', () => {
  test('expanding a failing job shows its event table', async ({ page }) => {
    await page.goto('/');
    await waitForRunRows(page);
    const runId = await runIdFromTable(page);
    const jobUuid = await failingJobUuid(page, runId);

    // The per-job view streams run + job + events.
    await page.goto(`/view/${runId}/${jobUuid}`);

    const events = await waitForEventRows(page);
    await expect.poll(async () => events.count(), { timeout: 30_000 }).toBeGreaterThan(0);

    // The failing assertion event (tag FAIL) is rendered and visible (FAIL is
    // not in the default-hidden set). It carries facet/tag classes set by
    // eventtable.modify_row.
    const failRow = page.locator('#jobs_events tbody tr.tag_FAIL').first();
    await expect(failRow).toBeVisible();
    await expect(failRow).toHaveClass(/event_line/);

    // The event filter control bar is rendered with at least one tag filter.
    await expect(page.locator('.event_filter li.filter').first()).toBeVisible();
  });

  test('a failing subtest auto-expands into nested event rows', async ({ page }) => {
    await page.goto('/');
    await waitForRunRows(page);
    const runId = await runIdFromTable(page);
    const jobUuid = await failingJobUuid(page, runId);

    await page.goto(`/view/${runId}/${jobUuid}`);
    await waitForEventRows(page);

    // eventtable.message_builder auto-calls load_subtest() for is_fail parents,
    // which fetches /event/<id>/events and appends rows carrying a
    // data-parent-id attribute. Wait for those nested rows to appear.
    await expect
      .poll(async () => page.locator('#jobs_events tbody tr[data-parent-id]').count(), {
        timeout: 30_000,
      })
      .toBeGreaterThan(0);

    // The subtest toggle widget is rendered and marked expanded.
    await expect(page.locator('#jobs_events .stoggle.expanded').first()).toBeVisible();
  });

  test('clicking a tag filter hides matching event rows (interaction)', async ({ page }) => {
    await page.goto('/');
    await waitForRunRows(page);
    const runId = await runIdFromTable(page);
    const jobUuid = await failingJobUuid(page, runId);

    await page.goto(`/view/${runId}/${jobUuid}`);
    await waitForEventRows(page);

    // FAIL is an active (not-off) filter that maps to visible rows. Pin the
    // locator to that exact tag so it does not "move" once we toggle it off
    // (a `:not(.off)` locator would re-resolve to a different filter).
    const tagText = 'FAIL';
    const filter = page.locator('.event_filter li.filter', { hasText: /^FAIL$/ }).first();
    await expect(filter).toBeVisible();
    await expect(filter).not.toHaveClass(/off/);
    const ctag = 'tag_' + tagText.replace(/[\W]+/g, '_');

    const matching = page.locator(`#jobs_events tbody tr.${ctag}`);
    await expect.poll(async () => matching.count(), { timeout: 10_000 }).toBeGreaterThan(0);

    // Before: none hidden.
    expect(await matching.evaluateAll((els) => els.some((e) => e.classList.contains('hidden_row')))).toBe(false);

    await filter.click();

    // After: clicking the filter toggles it off and hides the matching rows.
    await expect(filter).toHaveClass(/off/);
    await expect
      .poll(
        async () =>
          matching.evaluateAll((els) => els.every((e) => e.classList.contains('hidden_row'))),
        { timeout: 10_000 },
      )
      .toBe(true);
  });
});
