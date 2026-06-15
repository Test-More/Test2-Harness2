import { Page, expect } from '@playwright/test';

// The runtable/jobtable/eventtable are populated asynchronously by streaming
// JSONL over XHR (see share/js/main.js t2hui.fetch + view.js). There is no
// global "done" hook we can await for the all-runs stream (it stays open for
// live updates), so we poll the DOM for the rows we expect.

// IMPORTANT: each FieldTable row embeds nested tool/field <table>s, so a bare
// `#runs tbody tr` also matches those inner rows. Anchor on the table's own
// class and direct-child tbody to count only real data rows.
export async function waitForRunRows(page: Page) {
  const runs = page.locator('#runs table.run_table > tbody > tr');
  await expect.poll(async () => runs.count(), { timeout: 30_000 }).toBeGreaterThan(0);
  return runs;
}

export async function waitForJobRows(page: Page) {
  const jobs = page.locator('#jobs table.job_table > tbody > tr');
  await expect.poll(async () => jobs.count(), { timeout: 30_000 }).toBeGreaterThan(0);
  return jobs;
}

export async function waitForEventRows(page: Page) {
  // The event table renders rows tagged with the "event_line" class.
  const events = page.locator('#jobs_events tbody tr.event_line');
  await expect.poll(async () => events.count(), { timeout: 30_000 }).toBeGreaterThan(0);
  return events;
}

// DataTables marks a table it has initialized by adding the "dataTable" class
// and a wrapping element. We use that to assert "sortable" was applied.
export async function expectDataTableInitialized(page: Page, wrapperId: string) {
  const table = page.locator(`#${wrapperId} table.field-table`);
  await expect
    .poll(async () => (await table.getAttribute('class')) || '', { timeout: 30_000 })
    .toContain('dataTable');
}

// In single-run mode the run table's "Open Run" tool is an <a> linking to
// view/<run_uuid>. (runtable.js builds the link from item.run_uuid, so the id
// is a UUID, not the numeric run_id - matching the pre_ai server contract.)
// Returns that run identifier. We capture the whole final path segment rather
// than a digit run, because a `\d+` regex would clip a UUID at its first
// non-digit (e.g. "019EC9C6-..." -> "019"), yielding a bogus id that 404s.
export async function runIdFromTable(page: Page): Promise<string> {
  const goto = page.locator('#runs table.run_table > tbody > tr a[title="Open Run"]').first();
  await expect(goto).toBeVisible({ timeout: 30_000 });
  const href = await goto.getAttribute('href');
  const m = href && href.match(/view\/([^/?#]+)\/?$/);
  if (!m) throw new Error(`could not parse run id from href: ${href}`);
  return m[1];
}
