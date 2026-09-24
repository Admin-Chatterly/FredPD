import { expect, test } from '@playwright/test';
import type { Page } from '@playwright/test';

/**
 * Locations and premises (spec 7.6) against the mock bridge: the address
 * index, a hazard flagged on it, and the call card that shows it.
 */

async function openLocations(page: Page, locale = 'en'): Promise<void> {
  await page.goto(`/?locale=${locale}`);
  await page.locator('nav').first().getByRole('button', { name: locale === 'en' ? 'Records' : 'Register' }).click();
  await page.getByRole('button', { name: locale === 'en' ? 'Locations' : 'Adresser', exact: true }).click();
}

test('lists the address index with its standing hazards', async ({ page }) => {
  await openLocations(page);

  const row = page.getByRole('row').filter({ hasText: 'Alta Street at Power Street' });
  await expect(row.getByRole('cell').nth(2)).toHaveText('1');
});

test('reads a premise: its hazards, keyholders and the calls there', async ({ page }) => {
  await openLocations(page);

  await page.getByRole('button', { name: 'Alta Street at Power Street' }).click();

  await expect(page.getByText('Large dog in the yard, has bitten before.')).toBeVisible();
  // A lifted hazard stays on the record, marked as such.
  await expect(page.getByText(/withdrawn/)).toBeVisible();
  await expect(page.getByText(/Owner: Petrov, Marko/)).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Incidents at the address' })).toBeVisible();
});

test('flags a hazard, and lifts it again', async ({ page }) => {
  await openLocations(page);

  await page.getByRole('button', { name: '4 Vinewood Hills Drive' }).click();
  await page.getByRole('combobox', { name: /^Hazard/ }).selectOption('weapons');
  await page.getByLabel('Note', { exact: true }).fill('Hunting rifles in the garage.');
  await page.getByRole('button', { name: 'Add hazard' }).click();

  await expect(page.getByText('Hunting rifles in the garage.')).toBeVisible();

  await page.getByRole('button', { name: 'Withdraw the hazard: Weapons at the address' }).click();
  await expect(page.getByText(/withdrawn/)).toBeVisible();
});

test('registers an address at the officer’s own position', async ({ page }) => {
  await openLocations(page);

  await page.getByRole('button', { name: 'Add address' }).click();
  await page.getByLabel(/^Address/).fill('Mission Row Police Station');
  await page.locator('form').getByRole('button', { name: 'Add address' }).click();

  await expect(page.getByRole('heading', { name: 'Mission Row Police Station' })).toBeVisible();
  await expect(page.getByText(/Position on file/)).toBeVisible();
});

test('warns on the call card when the call is at a flagged premise', async ({ page }) => {
  await page.goto('/?locale=en');
  await page.locator('nav').first().getByRole('button', { name: 'Dispatch' }).click();
  await page.getByRole('button', { name: /Alta Street at Power Street/ }).first().click();

  const warning = page.getByRole('region', { name: 'Hazards at the address' });
  await expect(warning).toContainText('Hazard at Alta Street at Power Street');
  await expect(warning).toContainText('Dangerous dog (Large dog in the yard, has bitten before.)');
});

test('asks before removing a keyholder', async ({ page }) => {
  await openLocations(page);

  await page.getByRole('button', { name: 'Alta Street at Power Street' }).click();
  await page.getByRole('button', { name: 'Remove Petrov, Marko as keyholder' }).click();

  const dialog = page.getByRole('dialog');
  await expect(dialog).toContainText('Remove Petrov, Marko from this address?');
  await dialog.getByRole('button', { name: 'Remove keyholder' }).click();

  await expect(page.getByText('No keyholders recorded.')).toBeVisible();
});

test('says a keyholder needs a person, after the attempt', async ({ page }) => {
  await openLocations(page);

  await page.getByRole('button', { name: '4 Vinewood Hills Drive' }).click();
  await page.getByRole('button', { name: 'Add keyholder' }).click();

  await expect(page.getByRole('alert')).toContainText('Person');
});

test('renders the address index in Swedish', async ({ page }) => {
  await openLocations(page, 'sv');

  await page.getByRole('button', { name: 'Alta Street at Power Street' }).click();
  await expect(page.getByRole('listitem').filter({ hasText: 'Farlig hund' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Nyckelinnehavare' })).toBeVisible();
});
