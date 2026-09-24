import { expect, test } from '@playwright/test';

/**
 * The lab against the mock bridge (spec 8.7). A print search that hits a
 * reference names who it points at -- as a lead to confirm, never an
 * identification (8.1.3).
 */

test('a candidate match names the lead, and says it is not an identification', async ({ page }) => {
  await page.goto('/?locale=en');
  await page.locator('nav').first().getByRole('button', { name: 'Lab' }).click();

  await page.getByRole('button', { name: 'LSPD-2026-000127' }).click();

  await expect(page.getByText('Candidate — a lead to follow up')).toBeVisible();
  await expect(page.getByText('Petrov, Marko')).toBeVisible();
  await expect(page.getByText('1 more you may not see')).toBeVisible();
  await expect(page.getByText('Not an identification.')).toBeVisible();
});
