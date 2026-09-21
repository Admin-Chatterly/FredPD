import { expect, test } from '@playwright/test';
import type { Page } from '@playwright/test';

/**
 * Brottskatalogen and BrB 26:2 (spec 7.10).
 *
 * The catalogue is reference data; the test worth reading is the arithmetic.
 * Charging somebody with three offences does not give three times the range —
 * BrB 26:2 raises the maximum by a bounded amount above the severest single
 * offence and takes the severest minimum. That figure is quoted to a
 * prosecutor, so it comes from the server, and this asserts that the screen
 * shows what the server computed rather than a sum of its own.
 */

async function openCatalogue(page: Page): Promise<void> {
  await page.goto('/');

  await page.locator('nav').first().getByRole('button', { name: 'Records' }).click();
  await page.getByRole('button', { name: 'Offences', exact: true }).click();
}

test('lists offences with their citation and range', async ({ page }) => {
  await openCatalogue(page);

  const row = page.getByRole('row').filter({ hasText: 'Aggravated theft' });

  // The citation is derived on the server so there is one definition of it.
  await expect(row).toContainText('BrB 8:4');
  await expect(row).toContainText('at least 6 months, up to 6 years');
});

test('says which offences BrB 23 makes punishable earlier', async ({ page }) => {
  await openCatalogue(page);

  // Not every offence has an attempt, and charging one that does not is
  // refused on the anmälan with `stage_unavailable`.
  const aggravated = page.getByRole('row').filter({ hasText: 'Aggravated theft' });
  await expect(aggravated).toContainText('Attempt');

  const assault = page.getByRole('row').filter({ hasText: 'Assault' }).first();
  await expect(assault).not.toContainText('Attempt');
});

test('filters the catalogue', async ({ page }) => {
  await openCatalogue(page);

  await page.getByLabel('Find an offence').fill('8:4');

  await expect(page.getByRole('row').filter({ hasText: 'Aggravated theft' })).toBeVisible();
  await expect(page.getByRole('row').filter({ hasText: 'Assault' })).toHaveCount(0);
});

test('combines several charges the way BrB 26:2 does, not by adding them', async ({ page }) => {
  await openCatalogue(page);

  const theft = page.getByRole('row').filter({ hasText: 'Aggravated theft' });
  const assault = page.getByRole('row').filter({ hasText: 'Assault' }).first();

  await theft.getByRole('button', { name: 'Charge' }).click();

  // One charge alone: its own range, unchanged.
  await expect(page.getByText('Charges').locator('..')).toContainText(
    'at least 6 months, up to 6 years',
  );

  await assault.getByRole('button', { name: 'Charge' }).click();

  // Two: the severest maximum (6 years) raised by the statutory step, not
  // 6 + 2 = 8 years and not any other sum.
  await expect(page.getByText('Charges').locator('..')).toContainText(
    'at least 6 months, up to 8 years',
  );
});

test('counts three of the same offence as three counts', async ({ page }) => {
  await openCatalogue(page);

  const assault = page.getByRole('row').filter({ hasText: 'Assault' }).first();

  await assault.getByRole('button', { name: 'Charge' }).click();
  await assault.getByRole('button', { name: 'Charge' }).click();
  await assault.getByRole('button', { name: 'Charge' }).click();

  // BrB 26:2 is computed over counts, not over distinct offences — three
  // assaults is a real charge sheet and a heavier range than one.
  await expect(page.getByText('× 3')).toBeVisible();
  await expect(page.getByText('Charges').locator('..')).toContainText('up to 3 years');
});

test('shows how an offence used to read', async ({ page }) => {
  await openCatalogue(page);

  await page.getByRole('button', { name: 'BrB 8:4' }).click();

  // A record keeps the version it was charged under, so a report from March
  // still reads the way the statute read in March.
  await expect(page.getByRole('heading', { name: 'Versions of BRB-8-4' })).toBeVisible();
  await expect(page.getByText('Version 2')).toBeVisible();
  await expect(page.getByText(/Superseded/)).toBeVisible();
});

test('renders the catalogue in Swedish', async ({ page }) => {
  await page.goto('/?locale=sv');

  await page.locator('nav').first().getByRole('button', { name: 'Register' }).click();
  await page.getByRole('button', { name: 'Brottskatalog', exact: true }).click();

  const row = page.getByRole('row').filter({ hasText: 'Grov stöld' });

  await expect(row).toContainText('BrB 8:4');
  await expect(row).toContainText('Grov');
});

test('does not let the uplift exceed what the offences add up to', async ({ page }) => {
  await openCatalogue(page);

  // Two petty thefts, six months each. The band would add a year to the
  // heaviest — eighteen months — but BrB 26:2 caps the combined range at the
  // sum of the maxima, which is twelve. The fixture got this wrong before this
  // test existed, which is exactly the drift a fixture is able to hide.
  const petty = page.getByRole('row').filter({ hasText: 'Petty theft' });

  await petty.getByRole('button', { name: 'Charge' }).click();
  await petty.getByRole('button', { name: 'Charge' }).click();

  await expect(page.getByText('Charges').locator('..')).toContainText('up to 1 year');
});
