import { expect, test } from '@playwright/test';
import type { Page } from '@playwright/test';

/**
 * Intelligence writes against the mock bridge (spec 10, D3).
 *
 * `shell.spec.ts` covers the log and the three read-only lists this module
 * shipped with. This file is the other twenty-plus routes: create, update,
 * delete and merge for people, organizations and cases, plus the vehicles,
 * memberships, associates, case links and evidence hung off them. Every
 * write here is drawn for everybody and refused by the server (invariant 4),
 * so there is nothing to assert about who can press a button -- only that
 * pressing it does what the route promises.
 */

async function openIntel(page: Page, locale?: string): Promise<void> {
  const swedish = locale === 'sv';

  await page.goto(locale ? `/?locale=${locale}` : '/');
  await page
    .locator('nav')
    .first()
    .getByRole('button', { name: swedish ? 'Underrättelser' : 'Intelligence' })
    .click();
}

test('creates a person and opens the new record', async ({ page }) => {
  await openIntel(page);
  await page.getByRole('button', { name: 'People', exact: true }).click();

  await page.getByRole('button', { name: 'New person' }).click();

  const form = page.locator('form').filter({ hasText: 'Description' });
  await form.getByLabel('Name').fill('Reece Okafor');
  await form.getByLabel('Alias').fill('Fox');
  await form.getByRole('button', { name: 'Create' }).click();

  await expect(page.getByRole('heading', { name: 'Reece Okafor' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Reece Okafor', exact: false })).toBeVisible();
});

test('edits a person and shows the change', async ({ page }) => {
  await openIntel(page);
  await page.getByRole('button', { name: 'People', exact: true }).click();

  await page.getByRole('button', { name: 'Marko Petrov', exact: false }).first().click();
  await page.getByRole('button', { name: 'Edit' }).click();

  const form = page.locator('form').filter({ hasText: 'Description' }).last();
  await form.getByLabel('Description').fill('Now believed to be using a different vehicle.');
  await form.getByRole('button', { name: 'Save' }).click();

  // The same text now shows twice -- the list row picked up the edit too --
  // so this asserts on the detail panel specifically, the second in document
  // order.
  await expect(page.getByText('Now believed to be using a different vehicle.').last()).toBeVisible();
});

test('asks before deleting a person, and Escape cancels without deleting', async ({ page }) => {
  await openIntel(page);
  await page.getByRole('button', { name: 'People', exact: true }).click();

  await page.getByRole('button', { name: 'Ivy Turner', exact: false }).first().click();
  await page.getByRole('button', { name: 'Delete' }).click();

  const dialog = page.getByRole('dialog');
  await expect(dialog).toContainText('Ivy Turner');

  await page.keyboard.press('Escape');
  await expect(dialog).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Ivy Turner', exact: false })).toBeVisible();

  await page.getByRole('button', { name: 'Delete' }).click();
  await page.getByRole('dialog').getByRole('button', { name: 'Delete' }).click();

  await expect(page.getByRole('button', { name: 'Ivy Turner', exact: false })).toHaveCount(0);
});

test('merges one person into another', async ({ page }) => {
  await openIntel(page);
  await page.getByRole('button', { name: 'People', exact: true }).click();

  // Marko Petrov (1) keeps; the description-only tip (2) merges into him and
  // disappears from the list.
  await page.getByRole('button', { name: 'Marko Petrov', exact: false }).first().click();
  await page.getByRole('button', { name: 'Merge' }).click();

  const dialog = page.getByRole('dialog');
  await dialog.getByLabel('Merge in record id').fill('2');
  await dialog.getByRole('button', { name: 'Merge' }).click();

  await expect(page.getByText('Unknown person')).toHaveCount(0);
});

test('adds and removes a vehicle on a person', async ({ page }) => {
  await openIntel(page);
  await page.getByRole('button', { name: 'People', exact: true }).click();
  await page.getByRole('button', { name: 'Dean Ashworth', exact: false }).first().click();

  const vehicleForm = page.locator('form').filter({ hasText: 'Model' });
  await vehicleForm.getByLabel('Plate').fill('9plate01');
  await vehicleForm.getByRole('button', { name: 'Add vehicle' }).click();

  await expect(page.getByText('9PLATE01')).toBeVisible();

  const row = page.getByRole('listitem').filter({ hasText: '9PLATE01' });
  await row.getByRole('button', { name: 'Remove' }).click();
  await expect(page.getByText('9PLATE01')).toHaveCount(0);
});

test('adds and removes an associate on a person', async ({ page }) => {
  await openIntel(page);
  await page.getByRole('button', { name: 'People', exact: true }).click();
  await page.getByRole('button', { name: 'Dean Ashworth', exact: false }).first().click();

  const associateForm = page.locator('form').filter({ hasText: 'Relationship' });
  await associateForm.getByLabel('Person').fill('Ivy');
  await page.getByRole('option', { name: /Ivy Turner/ }).click();
  await associateForm.getByLabel('Relationship').fill('Cousin');
  await associateForm.getByRole('button', { name: 'Add associate' }).click();

  const row = page.getByText('Ivy Turner', { exact: false }).last();
  await expect(row).toContainText('Cousin');

  await row.locator('..').getByRole('button', { name: 'Remove' }).click();
  await expect(page.getByText('No associates recorded.')).toBeVisible();
});

test('creates an organization and adds a member', async ({ page }) => {
  await openIntel(page);
  await page.getByRole('button', { name: 'Organizations', exact: true }).click();

  await page.getByRole('button', { name: 'New organization' }).click();
  const createForm = page.locator('form').filter({ hasText: 'Territory' });
  await createForm.getByLabel('Name').fill('Popular Street Business Front');
  await createForm.getByRole('button', { name: 'Create' }).click();

  await expect(page.getByRole('heading', { name: 'Popular Street Business Front' })).toBeVisible();

  const memberForm = page.locator('form').filter({ hasText: 'Person id' });
  await memberForm.getByLabel('Person id').fill('2');
  await memberForm.getByRole('button', { name: 'Add member' }).click();

  await expect(page.getByText('Unknown person', { exact: false })).toBeVisible();
});

test('deletes an organization', async ({ page }) => {
  await openIntel(page);
  await page.getByRole('button', { name: 'Organizations', exact: true }).click();
  await page.getByRole('button', { name: 'Alta Street Crew', exact: false }).first().click();

  await page.getByRole('button', { name: 'Delete' }).click();
  await page.getByRole('dialog').getByRole('button', { name: 'Delete' }).click();

  await expect(page.getByRole('button', { name: 'Alta Street Crew', exact: false })).toHaveCount(0);
});

test('creates a case, links a person and unlinks them', async ({ page }) => {
  await openIntel(page);
  await page.getByRole('button', { name: 'Cases', exact: true }).click();

  await page.getByRole('button', { name: 'New case' }).click();
  const createForm = page.locator('form').filter({ hasText: 'Description' });
  await createForm.getByLabel('Title').fill('Operation Foxglove');
  await createForm.getByRole('button', { name: 'Create' }).click();

  await expect(page.getByRole('heading', { name: 'Operation Foxglove' })).toBeVisible();

  const linkForm = page.locator('form').filter({ hasText: 'Kind' });
  await linkForm.getByLabel('Record').fill('Ivy');
  await page.getByRole('option', { name: /Ivy Turner/ }).click();
  await linkForm.getByRole('button', { name: 'Link a record' }).click();

  const linked = page.getByText('Ivy Turner', { exact: false }).last();
  await expect(linked).toBeVisible();

  await linked.locator('..').getByRole('button', { name: 'Remove' }).click();
  await expect(page.getByText('Nothing linked to this case yet.')).toBeVisible();
});

test('adds evidence to a case', async ({ page }) => {
  await openIntel(page);
  await page.getByRole('button', { name: 'Cases', exact: true }).click();
  await page.getByRole('button', { name: 'Operation Kvarnen', exact: false }).first().click();

  const evidenceForm = page.locator('form').filter({ hasText: 'Caption' });
  await evidenceForm.getByLabel('Caption').fill('Wiretap transcript, page 4');
  await evidenceForm.getByRole('button', { name: 'Add evidence' }).click();

  await expect(page.getByText('Wiretap transcript, page 4')).toBeVisible();
});

test('renders the people screen in Swedish', async ({ page }) => {
  await openIntel(page, 'sv');
  await page.getByRole('button', { name: 'Personer', exact: true }).click();

  await page.getByRole('button', { name: 'Marko Petrov', exact: false }).first().click();
  await expect(page.getByRole('button', { name: 'Redigera' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Slå ihop' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Ta bort' })).toBeVisible();
});
