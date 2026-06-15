import { test, expect } from '@playwright/test';
import { waitForRunRows } from './helpers';

test.describe('main page', () => {
  test('loads with title, header, nav and lookup widget', async ({ page }) => {
    await page.goto('/');

    // <title>Yath</title>
    await expect(page).toHaveTitle(/Yath/i);

    // Branded header.
    await expect(page.locator('#header h1')).toHaveText('Test2-Harness-UI');

    // Main nav present (single-run hides Dashboard/Upload links but the nav
    // and the UUID lookup form are always rendered).
    await expect(page.locator('#nav_main')).toBeVisible();
    await expect(page.locator('#lookup')).toBeVisible();

    // Core front-end libraries actually loaded into the page. (Chart.js is
    // intentionally NOT loaded on the default views; it is pulled in only by
    // the project page - see 05-css-and-chart.spec.ts.)
    const libs = await page.evaluate(() => ({
      jquery: typeof (window as any).jQuery,
      jqueryui: typeof (window as any).jQuery?.ui,
      datatables: typeof (window as any).jQuery?.fn?.DataTable,
      jsonformatter: typeof (window as any).JSONFormatter,
      t2hui: typeof (window as any).t2hui,
    }));
    expect(libs.jquery).toBe('function');
    expect(libs.jqueryui).toBe('object');
    expect(libs.datatables).toBe('function');
    expect(libs.jsonformatter).toBe('function');
    expect(libs.t2hui).toBe('object');

    // The three streaming containers exist in the view template.
    await expect(page.locator('#run_list')).toBeAttached();
    await expect(page.locator('#job_list')).toBeAttached();
    await expect(page.locator('#event_list')).toBeAttached();
  });

  test('run table renders the imported run', async ({ page }) => {
    await page.goto('/');
    const rows = await waitForRunRows(page);

    // Exactly the one imported run in single-run mode.
    await expect(rows).toHaveCount(1);

    // The run is complete and failed (simple-fail demo): runtable.modify_row
    // tags failing runs with error_set.
    const row = rows.first();
    await expect(row).toHaveClass(/error_set/);
    await expect(row).toHaveClass(/complete_set/);

    // Status cell shows the textual status.
    await expect(row.locator('td.status')).toHaveText(/complete/i);

    // The pass/fail count columns are populated.
    await expect(row.locator('td.count').first()).toBeVisible();
  });
});
