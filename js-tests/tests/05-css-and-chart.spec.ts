import { test, expect } from '@playwright/test';
import { waitForRunRows } from './helpers';

test.describe('CSS rendering sanity', () => {
  test('header bar and layout wrappers are visible and laid out', async ({ page }) => {
    await page.goto('/');

    const header = page.locator('#header_wrapper');
    await expect(header).toBeVisible();

    // The header should sit at (or near) the top of the page and span width.
    const box = await header.boundingBox();
    expect(box).not.toBeNull();
    expect(box!.width).toBeGreaterThan(200);
    expect(box!.height).toBeGreaterThan(0);
    expect(box!.y).toBeLessThan(200);

    // Main and footer wrappers exist and the main content area is visible.
    await expect(page.locator('#main_wrapper')).toBeVisible();
    await expect(page.locator('#content')).toBeAttached();
    await expect(page.locator('#footer_wrapper')).toBeAttached();
  });

  test('stylesheets are applied (computed styles differ from UA defaults)', async ({ page }) => {
    await page.goto('/');

    // main.css gives #header_wrapper `position: fixed; background: white`.
    // Assert both resolved -> the stylesheet actually loaded and applied.
    const header = await page.evaluate(() => {
      const el = document.querySelector('#header_wrapper');
      if (!el) return null;
      const cs = getComputedStyle(el as Element);
      return { position: cs.position, background: cs.backgroundColor };
    });
    expect(header).not.toBeNull();
    expect(header!.position).toBe('fixed');
    // white === rgb(255, 255, 255)
    expect(header!.background).toBe('rgb(255, 255, 255)');

    // The H1 title is rendered with a real (non-zero) font size.
    const h1Size = await page.evaluate(() => {
      const el = document.querySelector('#header h1');
      return el ? parseFloat(getComputedStyle(el as Element).fontSize) : 0;
    });
    expect(h1Size).toBeGreaterThan(0);
  });

  test('run table is styled by fieldtable.css', async ({ page }) => {
    await page.goto('/');
    await waitForRunRows(page);

    const table = page.locator('#runs table.field-table');
    await expect(table).toBeVisible();

    // borderCollapse is set in fieldtable.css; default UA value is "separate".
    const collapse = await table.evaluate(
      (el) => getComputedStyle(el).borderCollapse,
    );
    expect(collapse).toBe('collapse');
  });

  test('main page screenshot snapshot', async ({ page }) => {
    await page.goto('/');
    await waitForRunRows(page);
    // Give the streamed table a beat to settle before snapshotting.
    await expect(page.locator('#runs tbody tr').first()).toBeVisible();
    await expect(page).toHaveScreenshot('main-page.png', {
      fullPage: true,
      maxDiffPixelRatio: 0.05,
    });
  });
});

test.describe('Chart.js', () => {
  test('Chart.js is loaded and the chart code path runs on the project page', async ({
    page,
  }) => {
    // chart.min.js + project.js (which calls `new Chart(canvas, ...)` for the
    // coverage/durations charts) are only pulled in by the project page, not
    // the default views. Discover the project name from the run row and load
    // its project page so the charting code path is actually loaded.
    await page.goto('/');
    await waitForRunRows(page);

    const projectLink = page
      .locator('#runs tbody tr td.project a[title^="See runs for"]')
      .first();
    await expect(projectLink).toBeVisible({ timeout: 30_000 });
    const projectName = (await projectLink.innerText()).trim();
    expect(projectName.length).toBeGreaterThan(0);

    await page.goto(`/project/${encodeURIComponent(projectName)}`);

    // Chart.js v3 is present and constructable on this page.
    const ok = await page.evaluate(() => {
      const C = (window as any).Chart;
      if (typeof C !== 'function') return false;
      return typeof C.version === 'string' && typeof C.register === 'function';
    });
    expect(ok).toBe(true);

    // project.js is loaded too (it owns the chart rendering via project_stats).
    const hasProjectJs = await page.evaluate(
      () => typeof (window as any).t2hui?.project_stats === 'object',
    );
    expect(hasProjectJs).toBe(true);
  });
});
