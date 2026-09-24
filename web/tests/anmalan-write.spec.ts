import { expect, test } from '@playwright/test';
import type { Page } from '@playwright/test';

/**
 * Writing a report (spec 7.7). The routes always existed; the screen could
 * only review. Now an officer starts one, writes what happened, adds the
 * offences and the people -- by name, from the catalogue -- and submits.
 */

async function openReports(page: Page): Promise<void> {
  await page.goto('/?locale=en');
  await page.locator('nav').first().getByRole('button', { name: 'Records' }).click();
  await page.getByRole('button', { name: 'Reports', exact: true }).click();
}

test('an officer writes a report from start to submit', async ({ page }) => {
  await openReports(page);

  await page.getByRole('button', { name: 'New report' }).click();
  await page.getByLabel('Title').fill('Theft from a parked car');
  await page.getByLabel('Where it happened').fill('Grove Street');
  await page.getByLabel('What happened').fill('Window smashed.\n\nA bag was taken from the back seat.');
  await page.getByRole('button', { name: 'Start the report' }).click();

  await expect(page.getByRole('heading', { name: 'Theft from a parked car' })).toBeVisible();
  // The narrative is shown as text, paragraphs intact.
  await expect(page.getByText('A bag was taken from the back seat.')).toBeVisible();

  await page.getByRole('button', { name: 'Change offences' }).click();
  await page.getByRole('searchbox', { name: /Find an offence/ }).fill('aggravated');
  await page.getByRole('checkbox', { name: /Aggravated theft/ }).check();
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(page.getByRole('listitem').filter({ hasText: 'Aggravated theft' })).toBeVisible();

  await page.getByLabel('Person', { exact: true }).fill('petrov');
  await page.getByRole('option', { name: /Petrov, Marko/ }).click();
  await page.getByLabel('As').selectOption('misstankt');
  await page.getByRole('button', { name: 'Add to the report' }).click();
  await expect(page.getByText('P-000588')).toBeVisible();

  await page.getByRole('button', { name: 'Submit for approval' }).click();
  await expect(page.getByText(/LSPD-26-\d+ · Submitted/)).toBeVisible();
});
