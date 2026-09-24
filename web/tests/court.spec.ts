import { expect, test } from '@playwright/test';
import type { Page } from '@playwright/test';

/**
 * Åtal och dom against the mock bridge (spec 7.20).
 *
 * The tests worth reading are the two capacity boundaries, because they are
 * the whole design of this module: an åklagare can decide whether to charge
 * a referral, and only a domare — never the same session, however many
 * permissions it holds — may then enter the disposition.
 */

async function openCourt(page: Page): Promise<void> {
  await page.goto('/?locale=en');
  await page.locator('nav').first().getByRole('button', { name: 'Court' }).click();
}

test('lists charged and declined referrals', async ({ page }) => {
  await openCourt(page);

  await expect(page.getByRole('button', { name: 'A26-00011' })).toBeVisible();
});

test('shows the disposition already entered on a charged referral', async ({ page }) => {
  await openCourt(page);

  await page.getByRole('button', { name: 'A26-00011' }).click();

  await expect(page.getByText('Guilty')).toBeVisible();
  // Exact: today's date can itself contain "18" (e.g. the 18th of a month),
  // which turns a substring match into a strict-mode collision between the
  // sentence length and a decided-at timestamp -- unrelated to what this
  // test checks.
  await expect(page.getByText('18', { exact: true })).toBeVisible();
});

test('shows the sentencing range the server computed, not one the screen adds up', async ({ page }) => {
  await openCourt(page);

  await page.getByRole('button', { name: 'A26-00011' }).click();

  // BrB 8:4, a single count: its own span, 6-72 months, not a sum.
  await expect(page.getByText('6–72')).toBeVisible();
});

test('lists redovisade investigations with no charging decision yet', async ({ page }) => {
  await openCourt(page);

  await page.getByRole('button', { name: 'Awaiting a charging decision' }).click();

  await expect(page.getByText('FU26-00030')).toBeVisible();
  // Already charged (A26-00011) and already declined referrals are not a
  // charging decision still to make.
  await expect(page.getByText('FU26-00022')).toHaveCount(0);
});

test('charges a referral', async ({ page }) => {
  await openCourt(page);

  await page.getByRole('button', { name: 'Awaiting a charging decision' }).click();
  await page.getByRole('listitem').getByRole('button', { name: 'Decide the referral' }).click();

  const form = page.locator('form').filter({ hasText: 'Choose a decision' });

  // Ticked from the catalogue, not typed as ids.
  await form.getByRole('searchbox', { name: /Find an offence/ }).fill('aggravated');
  await form.getByRole('checkbox', { name: /Aggravated theft/ }).check();
  await form.getByRole('button', { name: 'Decide the referral' }).click();
  await page.getByRole('dialog').getByRole('button', { name: 'Decide the referral' }).click();

  await expect(page.getByRole('status')).toContainText('charged');
  // Decided, so it drops off the pending queue.
  await expect(page.getByText('FU26-00030')).toHaveCount(0);
});

test('declines a referral, with a ground', async ({ page }) => {
  await openCourt(page);

  await page.getByRole('button', { name: 'Awaiting a charging decision' }).click();
  await page.getByRole('listitem').getByRole('button', { name: 'Decide the referral' }).click();

  const form = page.locator('form').filter({ hasText: 'Choose a decision' });
  await form.getByLabel('Choose a decision').selectOption('ej_atal');
  await form.getByLabel('Choose a ground').selectOption('otillrackliga_bevis');
  await form.getByRole('button', { name: 'Decide the referral' }).click();
  await page.getByRole('dialog').getByRole('button', { name: 'Decide the referral' }).click();

  await expect(page.getByRole('status')).toContainText('declined');
  await expect(page.getByText('Insufficient evidence')).toBeVisible();
});

test('refuses entering a disposition as not this officer’s decision', async ({ page }) => {
  await openCourt(page);

  // A26-00012: charged, awaiting a disposition.
  await page.getByRole('button', { name: 'A26-00012' }).click();
  await page.getByRole('button', { name: 'Enter disposition' }).click();

  const dialog = page.getByRole('dialog');
  await dialog.getByRole('button', { name: 'Enter disposition' }).click();

  const panel = dialog.getByRole('alert');

  // RB gives the disposition to the domare alone, and the åklagare who
  // charged the case is exactly the person it must never be.
  await expect(panel).toContainText('That decision is not yours to take.');
  await expect(panel).not.toContainText('wrong_capacity');
});

test('draws a declined referral it may not open as a restricted row', async ({ page }) => {
  await openCourt(page);

  await expect(page.getByText('Restricted record — Contact Internal Affairs')).toBeVisible();
  await expect(page.getByText('Restricted record — Contact Homicide')).toBeVisible();
});

test('Escape closes the dialog, not the whole interface', async ({ page }) => {
  await openCourt(page);

  await page.getByRole('button', { name: 'A26-00012' }).click();
  await page.getByRole('button', { name: 'Enter disposition' }).click();

  const dialog = page.getByRole('dialog');
  await expect(dialog).toBeVisible();

  await page.keyboard.press('Escape');

  await expect(dialog).toHaveCount(0);
  await expect(page.getByRole('heading', { name: 'A26-00012' })).toBeVisible();
});

test('renders the module in Swedish', async ({ page }) => {
  await page.goto('/?locale=sv');

  await page.locator('nav').first().getByRole('button', { name: 'Domstol' }).click();
  await page.getByRole('button', { name: 'A26-00011' }).click();

  await expect(page.getByRole('heading', { name: 'A26-00011' })).toBeVisible();
  await expect(page.getByRole('definition').filter({ hasText: 'Fällande dom' })).toBeVisible();
});
