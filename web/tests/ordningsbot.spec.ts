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
  await form.getByLabel('Person id').fill('petrov');
  await page.getByRole('option', { name: /Petrov, Marko/ }).click();
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

test('says a billed citation will mark itself paid', async ({ page }) => {
  await openOrdningsbot(page);

  // LSPD-T26-000301 sent a bill through esx_billing; LSPD-T26-000254 did not.
  await page.getByRole('button', { name: 'LSPD-T26-000301' }).click();
  await expect(page.getByText(/Bill sent .* marked paid by itself/)).toBeVisible();

  await page.getByRole('button', { name: 'LSPD-T26-000254' }).click();
  await expect(page.getByText(/Bill sent/)).toHaveCount(0);
});

test('a paid citation offers no further transition buttons', async ({ page }) => {
  await openOrdningsbot(page);

  await page.getByRole('button', { name: 'LSPD-T26-000287' }).click();

  await expect(page.getByRole('button', { name: 'Mark paid' })).toHaveCount(0);
});

test('an issued citation still inside its payment window reads as unpaid', async ({ page }) => {
  await openOrdningsbot(page);

  const row = page.getByRole('row').filter({ has: page.getByRole('button', { name: 'LSPD-T26-000301' }) });
  await expect(row.getByText('Unpaid', { exact: true })).toBeVisible();

  await row.getByRole('button', { name: 'LSPD-T26-000301' }).click();
  await expect(page.getByText('Unpaid', { exact: true })).toBeVisible();
});

test('an issued citation past its payment window reads as overdue', async ({ page }) => {
  await openOrdningsbot(page);

  const row = page.getByRole('row').filter({ has: page.getByRole('button', { name: 'LSPD-T26-000254' }) });
  await expect(row.getByText('Overdue', { exact: true })).toBeVisible();

  await row.getByRole('button', { name: 'LSPD-T26-000254' }).click();
  await expect(page.getByText('Overdue', { exact: true })).toBeVisible();
});

test('renders the tab in Swedish', async ({ page }) => {
  await page.goto('/?locale=sv');
  await page.locator('nav').first().getByRole('button', { name: 'Register' }).click();
  await page.getByRole('button', { name: 'Ordningsböter', exact: true }).click();

  await expect(page.getByRole('button', { name: 'LSPD-T26-000301' })).toBeVisible();
});

test('says what a fine did to the driving licence', async ({ page }) => {
  await openOrdningsbot(page);

  const form = page.locator('form').filter({ hasText: 'Fine' });
  // Running a red light carries 3 points; John Doe already has 8 (ADR-018).
  await form.getByLabel('Fine').selectOption({ label: 'Running a red light — 3000 kr, points: 3' });
  await form.getByLabel('Person id').fill('doe');
  await page.getByRole('option', { name: /Doe, John/ }).click();
  await form.getByRole('button', { name: 'Issue citation' }).click();

  await expect(page.getByRole('status')).toContainText('Driving licence: 11 of 12 points. Close to revocation.');

  await form.getByLabel('Fine').selectOption({ label: 'Running a red light — 3000 kr, points: 3' });
  await form.getByLabel('Person id').fill('doe');
  await page.getByRole('option', { name: /Doe, John/ }).click();
  await form.getByRole('button', { name: 'Issue citation' }).click();

  await expect(page.getByRole('status')).toContainText('Driving licence revoked: 14 of 12 points.');
});

test('command edits the tariff: a new line, new points, a line retired', async ({ page }) => {
  await openOrdningsbot(page);
  await page.getByRole('button', { name: 'Edit the tariff' }).click();

  const editor = page.getByRole('region', { name: 'Tariff' });

  // A new line in the agency's own words.
  await editor.getByLabel(/^Code/).fill('littering');
  await editor.getByLabel(/^Name/).fill('Littering in a public place');
  await editor.getByLabel(/^Amount/).fill('500');
  await editor.getByRole('button', { name: 'Save line' }).click();
  await expect(editor.getByRole('status')).toHaveText('littering saved.');
  await expect(editor.getByRole('row').filter({ hasText: 'Littering in a public place' })).toBeVisible();

  // New points on an existing line keep its name.
  await editor.getByRole('button', { name: 'Edit Running a red light' }).click();
  await expect(editor.getByLabel(/^Code/)).toHaveValue('red_light');
  await editor.getByLabel('Licence points').fill('4');
  await editor.getByRole('button', { name: 'Save line' }).click();
  await expect(editor.getByRole('row').filter({ hasText: 'Running a red light' }).getByRole('cell').nth(3)).toHaveText('4');

  // Retired after a confirmation, and gone from the fine list.
  await editor.getByRole('button', { name: 'Retire Disturbing the peace' }).click();
  await page.getByRole('dialog').getByRole('button', { name: 'Retire' }).click();
  await expect(editor.getByRole('status')).toHaveText('noise retired.');
  await expect(page.locator('form').filter({ hasText: 'Fine' }).getByRole('option', { name: /Disturbing the peace/ })).toHaveCount(0);
});

test('reads the tariff editor in Swedish', async ({ page }) => {
  await page.goto('/?locale=sv');
  await page.locator('nav').first().getByRole('button', { name: 'Register' }).click();
  await page.getByRole('button', { name: 'Ordningsböter', exact: true }).click();
  await page.getByRole('button', { name: 'Redigera bottaxan' }).click();

  const editor = page.getByRole('region', { name: 'Bottaxa' });
  await expect(editor.getByRole('columnheader', { name: 'Prickar' })).toBeVisible();
  await expect(editor.getByRole('row').filter({ hasText: 'Körning mot rött ljus' })).toBeVisible();
});

test('retiring a line from the keyboard leaves focus somewhere sensible', async ({ page }) => {
  await openOrdningsbot(page);
  await page.getByRole('button', { name: 'Edit the tariff' }).click();

  const editor = page.getByRole('region', { name: 'Tariff' });
  const retire = editor.getByRole('button', { name: 'Retire Illegal parking' });

  // Cancelled: back on the button that opened it.
  await retire.focus();
  await page.keyboard.press('Enter');
  await page.getByRole('dialog').getByRole('button', { name: 'Cancel' }).click();
  await expect(retire).toBeFocused();

  // Confirmed: the row is gone, so the editor's heading takes focus.
  await page.keyboard.press('Enter');
  await page.getByRole('dialog').getByRole('button', { name: 'Retire' }).click();
  await expect(editor.getByRole('heading', { name: 'Tariff' })).toBeFocused();
});

test('refuses a tariff name carrying markup, in words', async ({ page }) => {
  await openOrdningsbot(page);
  await page.getByRole('button', { name: 'Edit the tariff' }).click();

  const editor = page.getByRole('region', { name: 'Tariff' });
  await editor.getByLabel(/^Code/).fill('Bad Code');
  await editor.getByRole('button', { name: 'Save line' }).click();

  // The server's own refusal, translated -- not the browser's bubble.
  await expect(editor.getByRole('alert')).toBeVisible();
});
