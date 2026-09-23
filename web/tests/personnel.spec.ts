import { expect, test } from '@playwright/test';
import type { Page } from '@playwright/test';

/**
 * Personnel against the mock bridge (spec 7.22-7.24).
 *
 * The disciplinary file is the test worth reading: it ships stubbed to every
 * reader until an operator configures `internal_affairs` (spec 4.5), the
 * same closed-by-default posture `court`'s restricted åtal rows already
 * exercise -- this screen does not loosen it just because it is the one
 * asking.
 */

async function openPersonnel(page: Page): Promise<void> {
  await page.goto('/?locale=en');
  await page.locator('nav').first().getByRole('button', { name: 'Personnel' }).click();
}

test('lists the roster', async ({ page }) => {
  await openPersonnel(page);

  await expect(page.getByRole('button', { name: '12-40' })).toBeVisible();
  await expect(page.getByRole('button', { name: '12-41' })).toBeVisible();
});

test('opens an officer and shows equipment and certifications', async ({ page }) => {
  await openPersonnel(page);

  await page.getByRole('button', { name: '12-40' }).click();

  await expect(page.getByText('1042')).toBeVisible();
  await expect(page.getByText('RAD-118')).toBeVisible();
});

test('shows the disciplinary file as a restricted stub until revealed', async ({ page }) => {
  await openPersonnel(page);

  await page.getByRole('button', { name: '12-41' }).click();
  await page.getByRole('button', { name: 'Show' }).click();

  await expect(page.getByText('Restricted record — Contact Internal Affairs')).toBeVisible();
});

test('starts and ends a shift, only on the viewer’s own record', async ({ page }) => {
  await openPersonnel(page);

  // `personnel.shift.start`/`.end` act on the caller's own row, never a
  // colleague's -- the toggle must not appear on someone else's detail.
  await page.getByRole('button', { name: '12-41' }).click();
  await expect(page.getByRole('button', { name: 'Start shift' })).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'End shift' })).toHaveCount(0);

  await page.getByRole('button', { name: '12-40' }).click();
  await expect(page.getByRole('button', { name: 'End shift' })).toBeVisible();

  await page.getByRole('button', { name: 'End shift' }).click();
  await expect(page.getByRole('button', { name: 'Start shift' })).toBeVisible();
});

test('assigns equipment to an officer', async ({ page }) => {
  await openPersonnel(page);

  await page.getByRole('button', { name: '12-41' }).click();

  const form = page.locator('form').filter({ hasText: 'Assign' });
  await form.getByLabel('Item').selectOption('taser');
  await form.getByRole('button', { name: 'Assign' }).click();

  await expect(page.getByRole('listitem').getByText('Taser')).toBeVisible();
});

test('renders the module in Swedish', async ({ page }) => {
  await page.goto('/?locale=sv');
  await page.locator('nav').first().getByRole('button', { name: 'Personal' }).click();

  await expect(page.getByRole('button', { name: '12-40' })).toBeVisible();
});
