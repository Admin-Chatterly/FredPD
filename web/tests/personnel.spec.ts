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

test('refuses issuing an item gated behind a role or group the officer issuing it does not hold', async ({
  page,
}) => {
  await openPersonnel(page);

  await page.getByRole('button', { name: '12-41' }).click();

  const form = page.locator('form').filter({ hasText: 'Assign' });
  await form.getByLabel('Item').selectOption('less_lethal');
  await form.getByRole('button', { name: 'Assign' }).click();

  await expect(page.getByText('You do not hold the role or group this requires')).toBeVisible();
  await expect(page.getByRole('listitem').getByText('Less-lethal')).toHaveCount(0);
});

test('sets and clears an issue gate', async ({ page }) => {
  await openPersonnel(page);

  await page.getByRole('button', { name: 'Manage issue gates' }).click();

  // The fixture's own seeded gate.
  const row = page.getByRole('listitem').filter({ hasText: 'Less-lethal' });
  await expect(row).toContainText('swat');

  const setForm = page.locator('form').filter({ hasText: 'Set gate' });
  await setForm.getByLabel('Gates').selectOption('certification');
  await setForm.getByLabel('Item').selectOption('swat');
  await setForm.getByLabel('Required Discord role ID').fill('123456789012345678');
  await setForm.getByRole('button', { name: 'Set gate' }).click();

  // A case-sensitive regex, not the plain-string form of `hasText` (which
  // matches case-insensitively): the seeded gate's own "swat" group name,
  // lower-case, would otherwise also match "SWAT" the certification.
  const swatRow = page.getByRole('listitem').filter({ hasText: /SWAT/ }).first();
  await expect(swatRow).toContainText('123456789012345678');

  await row.getByRole('button', { name: 'Clear' }).click();
  await expect(page.getByRole('listitem').filter({ hasText: 'Less-lethal' })).toHaveCount(0);
});

test('shows the loadout assigned to an officer', async ({ page }) => {
  await openPersonnel(page);

  await page.getByRole('button', { name: '12-40' }).click();

  await expect(page.getByRole('paragraph').filter({ hasText: 'Patrol Basic' })).toBeVisible();
});

test('creates a loadout and assigns it to an officer', async ({ page }) => {
  await openPersonnel(page);

  await page.getByRole('button', { name: 'Manage loadouts' }).click();

  const createForm = page.locator('form').filter({ hasText: 'Create loadout' });
  await createForm.getByLabel('Loadout name').fill('SWAT Kit');
  await createForm.getByLabel('Taser', { exact: true }).check();
  await createForm.getByLabel('Less-lethal', { exact: true }).check();
  await createForm.getByRole('button', { name: 'Create loadout' }).click();

  await expect(page.getByText('SWAT Kit')).toBeVisible();

  // Closed so the create form's own "Loadout name" label does not also
  // match the filter below.
  await page.getByRole('button', { name: 'Manage loadouts' }).click();

  await page.getByRole('button', { name: '12-41' }).click();
  const assignForm = page.locator('form').filter({ hasText: 'Loadout' });
  await assignForm.getByLabel('Loadout').selectOption({ label: 'SWAT Kit' });
  await assignForm.getByRole('button', { name: 'Save' }).click();

  await expect(page.getByRole('paragraph').filter({ hasText: 'SWAT Kit' })).toBeVisible();
});

test('deletes a loadout, and unassigns it from the officer wearing it', async ({ page }) => {
  await openPersonnel(page);

  await page.getByRole('button', { name: 'Manage loadouts' }).click();
  const row = page.getByRole('listitem').filter({ hasText: 'Patrol Basic' });
  await row.getByRole('button', { name: 'Delete' }).click();

  await expect(page.getByText('Patrol Basic')).toHaveCount(0);

  await page.getByRole('button', { name: '12-40' }).click();
  await expect(page.getByText('No loadout assigned.')).toBeVisible();
});

test('renders the module in Swedish', async ({ page }) => {
  await page.goto('/?locale=sv');
  await page.locator('nav').first().getByRole('button', { name: 'Personal' }).click();

  await expect(page.getByRole('button', { name: '12-40' })).toBeVisible();
});

// ------------------------------------------------------------------ roles

test('promotes an officer through a Discord role, with a reason, after confirming', async ({ page }) => {
  await openPersonnel(page);
  await page.getByRole('button', { name: '12-41' }).click();

  const roles = page.getByRole('region', { name: 'Discord roles' });
  await expect(roles.getByText('Inspektör')).toBeVisible();
  await roles.getByRole('button', { name: 'Promote: Inspektör' }).click();

  const dialog = page.getByRole('dialog', { name: 'Promote' });
  await expect(dialog).toContainText('Give Inspektör?');
  await dialog.getByLabel(/Reason/).fill('Passed the inspector board');
  await dialog.getByRole('button', { name: 'Promote' }).click();

  await expect(roles.getByRole('status')).toHaveText('Inspektör was given.');
  // Focus comes back to the same row, now offering the opposite verb.
  await expect(roles.getByRole('button', { name: 'Demote: Inspektör' })).toBeFocused();
});

test('never offers an officer a change to their own roles', async ({ page }) => {
  await openPersonnel(page);
  await page.getByRole('button', { name: '12-40' }).click();

  const roles = page.getByRole('region', { name: 'Discord roles' });
  await expect(roles.getByText('You cannot change your own roles.')).toBeVisible();
  await expect(roles.getByRole('button', { name: /Promote|Demote|Hire|Dismiss/ })).toHaveCount(0);
});

test('Escape closes the role dialog, not the interface', async ({ page }) => {
  await openPersonnel(page);
  await page.getByRole('button', { name: '12-41' }).click();

  const roles = page.getByRole('region', { name: 'Discord roles' });
  await roles.getByRole('button', { name: 'Dismiss: Polis' }).click();
  await expect(page.getByRole('dialog', { name: 'Dismiss' })).toBeVisible();

  await page.keyboard.press('Escape');
  await expect(page.getByRole('dialog')).toHaveCount(0);
  await expect(roles.getByRole('button', { name: 'Dismiss: Polis' })).toBeFocused();
});

test('hires somebody new by Discord id, and says why when Discord does not know them', async ({ page }) => {
  await openPersonnel(page);

  await page.getByRole('button', { name: 'Hire a new member…' }).click();
  await page.getByLabel('Discord user id').fill('999999999999999999');
  await page.getByLabel(/Reason/).fill('Passed the academy');
  await page.getByRole('button', { name: 'Hire', exact: true }).click();
  await expect(page.getByRole('alert')).toContainText('that Discord user is not in the server');

  await page.getByLabel('Discord user id').fill('300000000000000003');
  await page.getByRole('button', { name: 'Hire', exact: true }).click();
  await expect(page.getByRole('status').filter({ hasText: 'Hired' })).toContainText('Hired with Polis.');
  await expect(page.getByRole('button', { name: 'Hire a new member…' })).toBeFocused();
});

test('promotes in Swedish, and refuses in Swedish', async ({ page }) => {
  await page.goto('/?locale=sv');
  await page.locator('nav').first().getByRole('button', { name: 'Personal' }).click();
  await page.getByRole('button', { name: '12-41' }).click();

  const roles = page.getByRole('region', { name: 'Discord-roller' });
  await roles.getByRole('button', { name: 'Befordra: Inspektör' }).click();
  const dialog = page.getByRole('dialog', { name: 'Befordra' });
  await dialog.getByLabel(/Skäl/).fill('Klarade inspektörsprovet');
  await dialog.getByRole('button', { name: 'Befordra' }).click();
  await expect(roles.getByRole('status')).toHaveText('Rollen Inspektör har tilldelats.');

  await page.getByRole('button', { name: 'Anställ en ny medlem…' }).click();
  await page.getByLabel('Användar-id i Discord').fill('999999999999999999');
  await page.getByLabel(/Skäl/).fill('Klar med utbildningen');
  await page.getByRole('button', { name: 'Anställ', exact: true }).click();
  await expect(page.getByRole('alert')).toContainText('Discord-användaren finns inte på servern');
});
