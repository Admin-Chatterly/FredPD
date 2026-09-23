import { expect, test } from '@playwright/test';
import type { Page } from '@playwright/test';

/**
 * Ordningsbot against the mock bridge (spec 7.11) -- on-the-spot fines
 * against a versioned tariff, the same immutable-version shape `fpd_brott`
 * and `fpd_atal_brott` use.
 */

async function openOrdningsbot(page: Page): Promise<void> {
  await page.goto('/?locale=en');
  await page.locator('nav').first().getByRole('button', { name: 'Records' }).click();
  await page.getByRole('button', { name: 'Citations', exact: true }).click();
}

test('lists citations', async ({ page }) => {
  await openOrdningsbot(page);

  await expect(page.getByRole('button', { name: 'LSPD-T26-000301' })).toBeVisible();
});

test('shows the tariff amount the citation was actually issued under', async ({ page }) => {
  await openOrdningsbot(page);

  await page.getByRole('button', { name: 'LSPD-T26-000301' }).click();

  await expect(page.getByRole('paragraph').filter({ hasText: 'Illegal parking' })).toContainText('800');
});

test('issues a citation against the fine schedule', async ({ page }) => {
  await openOrdningsbot(page);

  const form = page.locator('form').filter({ hasText: 'Fine' });
  await form.getByLabel('Fine').selectOption('2');
  await form.getByLabel('Person id').fill('9');
  await form.getByRole('button', { name: 'Issue citation' }).click();

  await expect(page.getByRole('status')).toContainText('issued');
});

test('voids an issued citation with a reason', async ({ page }) => {
  await openOrdningsbot(page);

  await page.getByRole('button', { name: 'LSPD-T26-000301' }).click();
  await page.getByRole('button', { name: 'Void' }).click();

  const dialog = page.getByRole('dialog');
  await dialog.getByLabel('Reason for voiding').selectOption('duplicate');
  await dialog.getByRole('button', { name: 'Void' }).click();

  await expect(page.getByText('Duplicate citation')).toBeVisible();
});

test('a paid citation offers no further transition buttons', async ({ page }) => {
  await openOrdningsbot(page);

  await page.getByRole('button', { name: 'LSPD-T26-000287' }).click();

  await expect(page.getByRole('button', { name: 'Mark paid' })).toHaveCount(0);
});

test('renders the tab in Swedish', async ({ page }) => {
  await page.goto('/?locale=sv');
  await page.locator('nav').first().getByRole('button', { name: 'Register' }).click();
  await page.getByRole('button', { name: 'Ordningsböter', exact: true }).click();

  await expect(page.getByRole('button', { name: 'LSPD-T26-000301' })).toBeVisible();
});
