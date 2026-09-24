import { expect, test } from '@playwright/test';
import type { Page } from '@playwright/test';

/**
 * Civilian mode (spec 7.29) against the mock bridge: the front desk a member
 * of the public uses, and the officers' inbox of what was handed in.
 */

async function openDesk(page: Page, locale = 'en', placementId = 1): Promise<void> {
  await page.goto(`/?locale=${locale}`);
  await expect(page.locator('nav').first()).toBeVisible();
  await page.evaluate((id) => window.postMessage({ type: 'fredpd:civilian', placementId: id }, '*'), placementId);
}

test('shows the visitor their own citations, court decisions and reports, without the MDT', async ({ page }) => {
  await openDesk(page);

  const desk = page.getByRole('region', { name: 'Police front desk' });
  await expect(desk).toBeVisible();
  await expect(page.locator('.fredpd-stage')).toBeHidden();
  await expect(desk.getByText('At the desk: Anna Svensson')).toBeVisible();

  await expect(desk.getByRole('cell', { name: 'LSPD-T26-000287' })).toBeVisible();
  await expect(desk.getByRole('cell', { name: 'Unpaid' })).toBeVisible();
  await expect(desk.getByRole('cell', { name: 'A26-00014' })).toBeVisible();
  await expect(desk.getByRole('cell', { name: '2 months' })).toBeVisible();
  await expect(desk.getByRole('cell', { name: 'LSPD-M26-000012' })).toBeVisible();
  // Somebody else's report is never the visitor's.
  await expect(desk.getByText('LSPD-M26-000013')).toHaveCount(0);
});

test('hands in a stolen-property report and sees it received', async ({ page }) => {
  await openDesk(page);
  const desk = page.getByRole('region', { name: 'Police front desk' });

  await desk.getByRole('button', { name: 'Hand in a report' }).click();
  await desk.getByLabel('Where did it happen?').fill('Legion Square');
  await desk.getByLabel(/What was taken/).fill('Black phone, IMEI 3569');
  await desk.getByLabel('Describe what happened').fill('Someone took my phone from the bench.');
  await desk.getByRole('button', { name: 'Hand in', exact: true }).click();

  await expect(desk.getByRole('status')).toContainText('Your report was received. Its number is LSPD-M26-');
  await expect(desk.getByRole('heading', { name: 'Police front desk' })).toBeFocused();
});

test('says in the visitor’s language why a report was refused', async ({ page }) => {
  await openDesk(page, 'sv');
  const desk = page.getByRole('region', { name: 'Polisens reception' });

  await desk.getByRole('button', { name: 'Lämna in en anmälan' }).click();
  await desk.getByLabel('Vad gäller det?').selectOption('complaint');
  await expect(desk.getByText(/läses av internutredningen/)).toBeVisible();
  await desk.getByLabel('Beskriv vad som hände').fill('kort');
  await desk.getByRole('button', { name: 'Lämna in', exact: true }).click();

  await expect(desk.getByRole('alert')).toContainText('Beskriv vad som hände');
});

test('refuses a desk the visitor is not standing at', async ({ page }) => {
  await openDesk(page, 'en', 99);
  const desk = page.getByRole('region', { name: 'Police front desk' });

  await expect(desk.getByRole('alert')).toContainText('you are not at the front desk');
});

test('leaves the desk with Escape', async ({ page }) => {
  await openDesk(page);
  const desk = page.getByRole('region', { name: 'Police front desk' });
  await expect(desk).toBeVisible();

  await page.keyboard.press('Escape');
  await expect(desk).toHaveCount(0);
});

test('an officer reads what was handed in and closes it', async ({ page }) => {
  await page.goto('/?locale=en');
  await page.locator('nav').first().getByRole('button', { name: 'Records' }).click();
  await page.getByRole('button', { name: 'From the public', exact: true }).click();

  const inbox = page.getByRole('region', { name: 'Reports from the public' });
  await inbox.getByRole('button', { name: /LSPD-M26-000012/ }).click();
  await expect(page.getByText('Red Whippet racing bike, frame number WH-44812')).toBeVisible();

  await page.getByRole('button', { name: 'Mark as handled' }).click();
  const dialog = page.getByRole('dialog', { name: 'Mark as handled' });
  await dialog.getByLabel('Note').fill('Written up as an anmälan.');
  await dialog.getByRole('button', { name: 'Mark as handled' }).click();

  await expect(page.getByRole('status')).toHaveText('LSPD-M26-000012 is closed.');
});

test('the inbox in Swedish', async ({ page }) => {
  await page.goto('/?locale=sv');
  await page.locator('nav').first().getByRole('button', { name: 'Register' }).click();
  await page.getByRole('button', { name: 'Från allmänheten', exact: true }).click();

  await expect(page.getByRole('heading', { name: 'Anmälningar från allmänheten' })).toBeVisible();
  await expect(page.getByText('Klagomål på polisen')).toBeVisible();
});
