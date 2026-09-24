import { expect, test } from '@playwright/test';
import type { Page } from '@playwright/test';

/**
 * The population register under a search: citizens and cars the game knows
 * with no record here yet. "Search does not find my own name" was this: the
 * MDT searched FredPD's registers only, and a character nobody had run a
 * check on had no record there to find.
 */

async function openRecords(page: Page, locale = 'en'): Promise<void> {
  await page.goto(`/?locale=${locale}`);
  await page.locator('nav').first().getByRole('button', { name: locale === 'en' ? 'Records' : 'Register' }).click();
}

test('finds a citizen with no record by full name, and opening creates the record', async ({ page }) => {
  await openRecords(page);
  await page.getByRole('button', { name: 'Persons', exact: true }).click();

  await page.getByRole('textbox', { name: 'Name, alias or record number' }).fill('Nora Ek');
  await page.getByRole('button', { name: 'Search', exact: true }).click();

  const population = page.getByRole('region', { name: 'In the population register, not yet on file' });
  await expect(population).toContainText('Ek, Nora');
  await expect(population).toContainText('1994-03-08');

  await population.getByRole('button', { name: 'Create a record for Ek, Nora' }).click();
  await expect(page.getByRole('heading', { name: /Ek, Nora|Nora Ek/ })).toBeVisible();

  // On file now: the same search finds the record, and no longer offers it as missing.
  await page.getByRole('button', { name: 'Search', exact: true }).click();
  await expect(page.getByRole('region', { name: 'In the population register, not yet on file' })).toHaveCount(0);
});

test('offers nothing from the population register for a name already on file', async ({ page }) => {
  await openRecords(page);
  await page.getByRole('button', { name: 'Persons', exact: true }).click();

  await page.getByRole('textbox', { name: 'Name, alias or record number' }).fill('doe');
  await page.getByRole('button', { name: 'Search', exact: true }).click();

  await expect(page.getByRole('region', { name: 'In the population register, not yet on file' })).toHaveCount(0);
});

test('finds an owned car with no record from the unified query, and opens it on the vehicle tab', async ({ page }) => {
  await openRecords(page);

  await page.getByRole('textbox', { name: 'Search' }).fill('NORA42');
  await page.getByRole('button', { name: 'Search', exact: true }).click();

  const population = page.getByRole('region', { name: 'In the vehicle register, not yet on file' });
  await population.getByRole('button', { name: 'Create a record for NORA42' }).click();

  await expect(page.getByRole('heading', { name: 'NORA42' })).toBeVisible();
});

test('in Swedish', async ({ page }) => {
  await openRecords(page, 'sv');
  await page.getByRole('button', { name: 'Personer', exact: true }).click();

  await page.getByRole('textbox', { name: 'Namn, alias eller registernummer' }).fill('Nora');
  await page.getByRole('button', { name: 'Sök', exact: true }).click();

  const population = page.getByRole('region', { name: 'I folkbokföringen, saknar post i FredPD' });
  await expect(population.getByRole('button', { name: 'Skapa post för Ek, Nora' })).toBeVisible();
});
