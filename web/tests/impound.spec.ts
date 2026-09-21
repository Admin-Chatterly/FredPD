import { expect, test } from '@playwright/test';
import type { Page } from '@playwright/test';

/**
 * Vehicle impound against the mock bridge (spec 7.15). `feeOwed` is the
 * server's own figure, sent fresh on every read -- this screen never adds it
 * up itself.
 */

async function openImpound(page: Page): Promise<void> {
  await page.goto('/');
  await page.locator('nav').first().getByRole('button', { name: 'Records' }).click();
  await page.getByRole('button', { name: 'Impound', exact: true }).click();
}

test('lists held vehicles', async ({ page }) => {
  await openImpound(page);

  await expect(page.getByRole('button', { name: 'ABC123' })).toBeVisible();
});

test('shows the fee owed the server computed', async ({ page }) => {
  await openImpound(page);

  await page.getByRole('button', { name: 'ABC123' }).click();

  await expect(page.getByText('100')).toBeVisible();
});

test('an investigative hold needs authorization before release', async ({ page }) => {
  await openImpound(page);

  await page.getByRole('button', { name: 'ABC123' }).click();

  await expect(page.getByRole('button', { name: 'Authorize hold' })).toBeVisible();
});

test('creates an impound record', async ({ page }) => {
  await openImpound(page);

  const form = page.locator('form').filter({ hasText: 'Plate' });
  await form.getByLabel('Plate').fill('NEW999');
  await form.getByLabel('Reason held').selectOption('dui');
  await form.getByRole('button', { name: 'Impound vehicle' }).click();

  await expect(page.getByRole('status')).toContainText('recorded');
});

test('draws a restricted impound as a stub', async ({ page }) => {
  await openImpound(page);

  await expect(page.getByText('Restricted record — Contact Narcotics')).toBeVisible();
});

test('renders the tab in Swedish', async ({ page }) => {
  await page.goto('/?locale=sv');
  await page.locator('nav').first().getByRole('button', { name: 'Register' }).click();
  await page.getByRole('button', { name: 'Beslag', exact: true }).click();

  await expect(page.getByRole('button', { name: 'ABC123' })).toBeVisible();
});
