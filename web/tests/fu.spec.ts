import { expect, test } from '@playwright/test';
import type { Page } from '@playwright/test';

/**
 * Förundersökning — the investigation (spec 7.8).
 *
 * The anmälan tab beside it holds the *reports*: what happened, who was there,
 * locked when a supervisor approves. This is the case opened off the back of
 * one, and the tests worth reading are about its three endings, which are
 * three different facts rather than three buttons:
 *
 *   * **Slutdelgivning** (RB 23:18a) is the suspect being shown the material,
 *     and the investigation carries on afterwards.
 *   * **Redovisning** hands it to the prosecutor.
 *   * **Nedläggning** ends it and asks why, because "the offence cannot be
 *     proven" and "no offence was committed" are not the same answer to give
 *     somebody who was a suspect.
 */

async function openInvestigations(page: Page): Promise<void> {
  await page.goto('/');

  await page.locator('nav').first().getByRole('button', { name: 'Records' }).click();
  await page.getByRole('button', { name: 'Investigations', exact: true }).click();
}

test('lists the investigations and who leads each', async ({ page }) => {
  await openInvestigations(page);

  const police = page.getByRole('row').filter({ hasText: 'FU26-00031' });
  await expect(police).toContainText('Police investigation leader');

  // Once somebody is anhållen the prosecutor takes it (ADR-014), and the
  // capacity is what the list shows rather than an account id.
  const prosecutor = page.getByRole('row').filter({ hasText: 'FU26-00028' });
  await expect(prosecutor).toContainText('Prosecutor');
});

test('lists the reports gathered under an investigation', async ({ page }) => {
  await openInvestigations(page);

  await page.getByRole('button', { name: 'FU26-00031' }).click();

  await expect(page.getByRole('heading', { name: 'Reports under this investigation' })).toBeVisible();
  // The report numbers the anmälan register issued, under the case they
  // belong to — which is what "a förundersökning gathers anmälningar" means
  // on screen.
  await expect(page.getByText(/LSPD-26-\d+/).first()).toBeVisible();
});

test('opens an investigation', async ({ page }) => {
  await openInvestigations(page);

  await page.getByRole('button', { name: 'Open investigation' }).click();

  // Anchored on "Title", which only the create form has: the filter row
  // beside it also says "Led by me".
  const form = page.locator('form').filter({ hasText: 'Title' });

  await form.getByLabel('Title').fill('Vehicle thefts, the docks');
  await form.getByRole('button', { name: 'Open investigation' }).click();

  await expect(page.getByRole('heading', { name: /^FU26-/ })).toBeVisible();
  await expect(page.getByText('No reports have been gathered under it yet.')).toBeVisible();
});

test('disclosure does not end the investigation', async ({ page }) => {
  await openInvestigations(page);

  await page.getByRole('button', { name: 'FU26-00031' }).click();
  await page.getByRole('button', { name: 'Disclose the material' }).click();
  await page.getByRole('dialog').getByRole('button', { name: 'Disclose the material' }).click();

  await expect(page.getByRole('status')).toContainText('disclosed to the suspect');

  // RB 23:18a is a step, not a closure: the case carries on and can still be
  // reported or discontinued.
  await expect(page.getByRole('button', { name: 'Report to the prosecutor' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Discontinue' })).toBeVisible();
});

test('asks why an investigation is being discontinued', async ({ page }) => {
  await openInvestigations(page);

  await page.getByRole('button', { name: 'FU26-00031' }).click();
  await page.getByRole('button', { name: 'Discontinue' }).click();

  const dialog = page.getByRole('dialog');

  await expect(dialog).toContainText('the reason is what the suspect is told');
  await dialog.getByLabel('Reason').selectOption('ej_brott');
  await dialog.getByRole('button', { name: 'Discontinue' }).click();

  await expect(page.getByText('No offence was committed')).toBeVisible();
});

test('offers no ending for an investigation that has one', async ({ page }) => {
  await openInvestigations(page);

  await page.getByRole('button', { name: 'FU26-00019' }).click();

  // Discontinued. There is nothing left to decide, and the reason it ended
  // stays on the record.
  await expect(page.getByText('The offence cannot be proven')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Discontinue' })).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Report to the prosecutor' })).toHaveCount(0);
});

test('Escape closes the dialog, not the whole interface', async ({ page }) => {
  await openInvestigations(page);

  await page.getByRole('button', { name: 'FU26-00031' }).click();
  await page.getByRole('button', { name: 'Discontinue' }).click();

  const dialog = page.getByRole('dialog');
  await expect(dialog).toBeVisible();

  await page.keyboard.press('Escape');

  await expect(dialog).toHaveCount(0);
  await expect(page.getByRole('heading', { name: 'FU26-00031' })).toBeVisible();
});

test('draws an investigation it may not open as a restricted row', async ({ page }) => {
  await openInvestigations(page);

  await expect(page.getByText('Restricted record — Contact Internal Affairs')).toBeVisible();
  await expect(page.getByText('Restricted record — Contact Homicide')).toBeVisible();
});

test('renders the investigation tab in Swedish', async ({ page }) => {
  await page.goto('/?locale=sv');

  await page.locator('nav').first().getByRole('button', { name: 'Register' }).click();
  await page.getByRole('button', { name: 'Förundersökningar', exact: true }).click();

  const row = page.getByRole('row').filter({ hasText: 'FU26-00028' });

  await expect(row).toContainText('Åklagare');
  await expect(row).toContainText('Slutdelgiven');
});
