import { test, expect, Page } from '@playwright/test';
import {
  waitForRunRows,
  runIdFromTable,
  expectDataTableInitialized,
} from './helpers';

// True job rows are the direct <tr> children of the job table's own <tbody>.
// (`#jobs tbody tr` also matches the nested tool/field tables inside a row, so
// we must anchor on `table.job_table > tbody > tr`.)
const JOB_ROWS = '#jobs table.job_table > tbody > tr';

async function openRun(page: Page): Promise<string> {
  await page.goto('/');
  await waitForRunRows(page);
  const runId = await runIdFromTable(page);
  await page.goto(`/view/${runId}`);
  // Wait for the run-scoped stream to finish wiring up the job table.
  await expect.poll(async () => page.locator(JOB_ROWS).count(), { timeout: 30_000 }).toBeGreaterThan(0);
  return runId;
}

test.describe('run view (jobs)', () => {
  test('drilling into the run shows the job table with real job rows', async ({ page }) => {
    await openRun(page);

    // At least one real job row, carrying a test file name.
    const rows = page.locator(JOB_ROWS);
    await expect(rows.first()).toBeVisible();
    await expect(page.locator(`${JOB_ROWS} td.job_name`).first()).toContainText(/\.t/);

    // Job rows are status-tagged by jobtable.modify_row (e.g. success_set).
    await expect(page.locator(`${JOB_ROWS}.success_set`).first()).toBeVisible();

    // The job-table tool column renders the "Open Job" / params tools.
    await expect(
      page.locator(`${JOB_ROWS} td.tools div.tool[title="See Job Parameters"]`).first(),
    ).toBeAttached();
  });

  test('the run-scoped stream terminates and DataTables sorting is initialized', async ({ page }) => {
    await openRun(page);

    // The per-run stream completes, firing the "done" hook in view.js which
    // calls make_sortable() -> DataTable() on both tables.
    await expectDataTableInitialized(page, 'jobs');
    await expectDataTableInitialized(page, 'runs');
  });

  test('clicking a job-table column header drives the DataTables sort', async ({ page }) => {
    await openRun(page);
    await expectDataTableInitialized(page, 'jobs');

    // DataTables tags sortable headers with the "sorting" class and marks the
    // active sort column with sorting_asc / sorting_desc. Clicking the
    // "file/job name" header should make it the active sort column.
    const header = page.locator('#jobs table.job_table thead th.col-job_name');
    await expect(header).toBeVisible();
    await expect(header).toHaveClass(/sorting/);

    await header.locator('.field-table-header-col-inner').click();
    await expect(header).toHaveClass(/sorting_(asc|desc)/);

    // Clicking again keeps it the active sort column (asc or desc).
    const dir1 = (await header.getAttribute('aria-sort')) || '';
    await header.locator('.field-table-header-col-inner').click();
    await expect(header).toHaveClass(/sorting_(asc|desc)/);
    const dir2 = (await header.getAttribute('aria-sort')) || '';
    // The aria-sort direction reflects the active ordering; it should be a real
    // direction both times (and typically flips between the two clicks).
    expect(['ascending', 'descending']).toContain(dir2 || dir1);
  });
});
