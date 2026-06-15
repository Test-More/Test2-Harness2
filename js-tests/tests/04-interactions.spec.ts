import { test, expect } from '@playwright/test';
import { waitForRunRows } from './helpers';

test.describe('interactive widgets', () => {
  test('the run "parameters" tool opens the JSONFormatter modal', async ({ page }) => {
    await page.goto('/');
    await waitForRunRows(page);

    const modal = page.locator('#free_modal');
    await expect(modal).toBeHidden();

    // tool_builder adds a div.tool with title "See Run Parameters" that, when
    // clicked, slides down #free_modal and renders the params via JSONFormatter.
    const paramsTool = page
      .locator('#runs tbody tr div.tool[title="See Run Parameters"]')
      .first();
    await expect(paramsTool).toBeVisible();
    await paramsTool.click();

    await expect(modal).toBeVisible();
    // JSONFormatter renders a div.json-formatter-row inside #modal_body.
    await expect(page.locator('#modal_body')).not.toBeEmpty();

    // Clicking the backdrop / close control hides the modal again.
    await page.locator('#modal_close').click();
    await expect(modal).toBeHidden();
  });

  test('the UUID lookup form is wired and submits to /lookup', async ({ page }) => {
    await page.goto('/');

    const input = page.locator('#lookup');
    await expect(input).toBeVisible();

    // Fill a bogus uuid and submit; the form action is the lookup controller.
    await input.fill('00000000-0000-0000-0000-000000000000');
    await Promise.all([
      page.waitForURL(/\/lookup/, { timeout: 15_000 }),
      page.locator('#nav_main form input[type="submit"]').click(),
    ]);

    // The lookup page renders (header still present).
    await expect(page.locator('#header h1')).toHaveText('Test2-Harness-UI');
  });
});
