import { expect, test } from '@playwright/test';
import type { Page } from '@playwright/test';

/**
 * Vehicle impound against the mock bridge (spec 7.15). `feeOwed` is the
 * server's own figure, sent fresh on every read -- this screen never adds it
 * up itself.
 */

async function openImpound(page: Page): Promise<void> {
  await page.goto('/?locale=en');
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

test('shows where a held car stands and what it was found with', async ({ page }) => {
  await openImpound(page);

  const row = page.getByRole('row').filter({ has: page.getByRole('button', { name: 'ABC123' }) });
  await expect(row.getByRole('cell', { name: '41 · A3' })).toBeVisible();

  await page.getByRole('button', { name: 'ABC123' }).click();
  await expect(page.getByText('Lot 41, bay A3')).toBeVisible();
  await expect(page.getByText("In the lot's key safe")).toBeVisible();
  await expect(page.getByText('Gym bag (empty), two phone chargers, parking receipt.')).toBeVisible();
  await expect(page.getByText(/Inventory by 1-ADAM-12/)).toBeVisible();
});

test('writes the inventory: the lot, the bay, the keys, the contents', async ({ page }) => {
  await openImpound(page);

  await page.getByRole('button', { name: 'ABC123' }).click();
  await page.getByRole('button', { name: 'Edit inventory' }).click();

  const form = page.locator('form').filter({ hasText: 'Left in the vehicle' });
  await form.getByRole('combobox', { name: /^Lot/ }).selectOption({ label: 'Lot 57' });
  await form.getByLabel('Bay').fill('C1');
  await form.getByRole('combobox', { name: /^Keys/ }).selectOption('with_owner');
  await form.getByLabel('Left in the vehicle').fill('Nothing of value.');
  await form.getByRole('button', { name: 'Save inventory' }).click();

  await expect(page.getByRole('status')).toHaveText('Inventory saved.');
  await expect(page.getByText('With the owner')).toBeVisible();
  await expect(page.getByText('Nothing of value.')).toBeVisible();
  await expect(page.getByRole('row').filter({ has: page.getByRole('button', { name: 'ABC123' }) })).toContainText(
    '57 · C1',
  );
});

test('an impound made at the desk can name its lot', async ({ page }) => {
  await openImpound(page);

  const form = page.locator('form').filter({ hasText: 'Plate' });
  await form.getByLabel('Plate').fill('LOT222');
  await form.getByLabel('Reason held').selectOption('abandoned');
  await form.getByLabel('Lot').selectOption({ label: 'Lot 57' });
  await form.getByRole('button', { name: 'Impound vehicle' }).click();

  await expect(page.getByRole('row').filter({ has: page.getByRole('button', { name: 'LOT222' }) })).toContainText(
    '57',
  );
});

test('names the lot in Swedish', async ({ page }) => {
  await page.goto('/?locale=sv');
  await page.locator('nav').first().getByRole('button', { name: 'Register' }).click();
  await page.getByRole('button', { name: 'Beslag', exact: true }).click();

  await page.getByRole('button', { name: 'ABC123' }).click();
  await expect(page.getByText('Uppställningsplats 41, ruta A3')).toBeVisible();
});

test('the inventory form works from the keyboard, and Escape closes only the form', async ({ page }) => {
  await openImpound(page);
  await page.getByRole('button', { name: 'ABC123' }).click();

  const trigger = page.getByRole('button', { name: 'Edit inventory' });
  await trigger.focus();
  await page.keyboard.press('Enter');
  const form = page.locator('form').filter({ hasText: 'Left in the vehicle' });
  await expect(form.getByRole('combobox', { name: /^Lot/ })).toBeFocused();

  // Escape backs out of the form, not the MDT.
  await page.keyboard.press('Escape');
  await expect(trigger).toBeFocused();

  await page.keyboard.press('Enter');
  await page.getByLabel('Left in the vehicle').fill('A toolbox.');
  await page.getByLabel('Left in the vehicle').press('Control+Enter');

  await expect(page.getByRole('status')).toHaveText('Inventory saved.');
  await expect(page.getByText('A toolbox.')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Edit inventory' })).toBeFocused();
});
