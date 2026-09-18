import { expect, test } from '@playwright/test';
import type { Page } from '@playwright/test';

/**
 * The report workflow against the mock bridge (spec 7.7, 15).
 *
 * Two of these matter more than the rest, and both are about a refusal being
 * *legible* rather than about a button working:
 *
 *   * **An author cannot approve their own anmälan.** No permission reaches
 *     that rule, so an officer refused with a bare "forbidden" concludes their
 *     role is wrong and goes to ask for a grant that would not have helped.
 *     The note has to be on the screen before the button is pressed.
 *   * **An approved anmälan is locked.** The screen must stop offering to
 *     submit it, because 7.7's whole amendment model is that a locked record
 *     gains a tilläggsuppgift rather than being edited.
 *
 * The rest is the frame: the tab opens, the list draws, a record opens, and the
 * straffskala the server computed is the one shown.
 */

/** Opens Records and switches to the reports tab. */
async function openReports(page: Page): Promise<void> {
  await page.goto('/');

  await page.locator('nav').first().getByRole('button', { name: 'Records' }).click();
  await page.getByRole('button', { name: 'Reports', exact: true }).click();
}

test('lists the reports the session may see', async ({ page }) => {
  await openReports(page);

  await expect(page.getByRole('button', { name: 'LSPD-26-000101' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'LSPD-26-000102' })).toBeVisible();
});

test('opens a report and shows the charge with its citation', async ({ page }) => {
  await openReports(page);

  await page.getByRole('button', { name: 'LSPD-26-000102' }).click();

  await expect(page.getByText('Misshandel utanför Vanilla Unicorn')).toBeVisible();
  // The citation is an identifier and reads the same in both languages.
  await expect(page.getByText('BrB 3:5')).toBeVisible();
  await expect(page.getByText('Assault')).toBeVisible();
});

test('shows the sentencing range the server computed', async ({ page }) => {
  await openReports(page);

  await page.getByRole('button', { name: 'LSPD-26-000102' }).click();

  // 36 months arrives from the server and renders as three years; the screen
  // does no arithmetic of its own on it (BrB 26:2 is the server's).
  await expect(page.getByText('up to 3 years')).toBeVisible();
});

test('offers to submit a draft', async ({ page }) => {
  await openReports(page);

  await page.getByRole('button', { name: 'LSPD-26-000101' }).click();

  await expect(page.getByRole('button', { name: 'Submit for approval' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Approve' })).toHaveCount(0);
});

test('warns the author before they try to approve their own report', async ({ page }) => {
  await openReports(page);

  // LSPD-26-000103 was written by the viewer and submitted by them.
  await page.getByRole('button', { name: 'LSPD-26-000103' }).click();

  await expect(
    page.getByText('You cannot approve a report you wrote.'),
  ).toBeVisible();
});

test('refuses the own-approval and says why', async ({ page }) => {
  await openReports(page);

  await page.getByRole('button', { name: 'LSPD-26-000103' }).click();
  await page.getByRole('button', { name: 'Approve' }).click();

  // The refusal is drawn rather than swallowed (invariant 4, spec 6.4).
  await expect(page.getByText('You cannot approve a report you wrote.').first()).toBeVisible();
});

test('locks an approved report against being submitted again', async ({ page }) => {
  await openReports(page);

  await page.getByRole('button', { name: 'LSPD-26-000102' }).click();
  await page.getByRole('button', { name: 'Approve' }).click();

  await expect(
    page.getByText('Approved and locked. Add a supplemental to amend it.'),
  ).toBeVisible();

  await expect(page.getByRole('button', { name: 'Submit for approval' })).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Approve' })).toHaveCount(0);
});

test('renders the reports tab in Swedish', async ({ page }) => {
  await page.goto('/?locale=sv');

  await page.locator('nav').first().getByRole('button', { name: 'Register' }).click();
  await page.getByRole('button', { name: 'Anmälningar', exact: true }).click();

  await expect(page.getByRole('button', { name: 'LSPD-26-000101' })).toBeVisible();

  await page.getByRole('button', { name: 'LSPD-26-000103' }).click();

  await expect(
    page.getByText('Du kan inte godkänna en anmälan du själv har upprättat.'),
  ).toBeVisible();
});
