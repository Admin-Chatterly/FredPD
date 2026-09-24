import { expect, test } from '@playwright/test';
import type { Page } from '@playwright/test';

/**
 * Efterlysningar against the mock bridge (spec 7.13).
 *
 * The test that matters is the third one. Two of the six grounds mean *detain
 * this person* and the other four emphatically do not: somebody to be served a
 * document is not somebody to arrest, and a missing person is wanted for their
 * own sake. An interface that drew all six the same way would teach officers
 * to arrest missing people, and `Tvang.detainOnSight` exists so that it cannot.
 */

async function openWanted(page: Page): Promise<void> {
  await page.goto('/?locale=en');

  await page.locator('nav').first().getByRole('button', { name: 'Records' }).click();
  await page.getByRole('button', { name: 'Wanted notices', exact: true }).click();
}

test('lists the live notices, and not the lifted', async ({ page }) => {
  await openWanted(page);

  await expect(page.getByRole('cell', { name: 'W26-00115' })).toBeVisible();
  await expect(page.getByRole('cell', { name: 'W26-00112' })).toBeVisible();

  // W26-00099 was lifted when the person was taken into custody.
  await expect(page.getByRole('cell', { name: 'W26-00099' })).toHaveCount(0);
});

test('shows a lifted notice, and why it was lifted, once the filter is cleared', async ({
  page,
}) => {
  await openWanted(page);

  await page.getByLabel('Include lifted notices').check();
  await page.getByRole('button', { name: 'Search' }).click();

  const row = page.getByRole('row').filter({ hasText: 'W26-00099' });

  await expect(row).toContainText('Lifted');
  await expect(row).toContainText('Arrested');
});

test('marks detain-on-sight, and marks the others as not that', async ({ page }) => {
  await openWanted(page);

  // Anhållen i sin frånvaro: a prosecutor has decided this person be detained.
  const detain = page.getByRole('row').filter({ hasText: 'W26-00115' });
  await expect(detain).toContainText('Detain on sight');

  // Delgivning: wanted to be handed a document. The line has to say so, not
  // merely leave the loud one off.
  const serve = page.getByRole('row').filter({ hasText: 'W26-00112' });
  await expect(serve).toContainText('Wanted, but not for arrest.');
  await expect(serve).not.toContainText('Detain on sight');

  // A missing person is the same problem facing the other way.
  const missing = page.getByRole('row').filter({ hasText: 'W26-00105' });
  await expect(missing).not.toContainText('Detain on sight');
});

test('says that a notice with no expiry stands until it is lifted', async ({ page }) => {
  await openWanted(page);

  // A prosecutor's decision does not lapse because time passed, so an empty
  // expiry is a real state and reads as one rather than as a blank cell.
  const row = page.getByRole('row').filter({ hasText: 'W26-00115' });

  await expect(row).toContainText('Until lifted');
});

test('renders the issue date in this decade', async ({ page }) => {
  await openWanted(page);

  // `UNIX_TIMESTAMP` is seconds. Read as milliseconds this said 1970.
  const row = page.getByRole('row').filter({ hasText: 'W26-00115' });

  await expect(row).toContainText(String(new Date().getFullYear()));
});

test('issues a notice', async ({ page }) => {
  await openWanted(page);

  await page.getByRole('button', { name: 'Issue a wanted notice' }).click();

  const form = page.locator('form').filter({ hasText: 'Person id' });

  await form.getByLabel('Person id').fill('petrov');
  await page.getByRole('option', { name: /Petrov, Marko/ }).click();
  await form.getByLabel('Ground').selectOption('haktad_i_franvaro');
  await form.getByRole('button', { name: 'Issue a wanted notice' }).click();

  const row = page.getByRole('row').filter({ hasText: 'P-001003' });

  await expect(row).toContainText('Remanded in absentia');
  // Häktad i sin frånvaro is the second of the two detain-on-sight grounds.
  await expect(row).toContainText('Detain on sight');
});

test('asks why a notice is being lifted', async ({ page }) => {
  await openWanted(page);

  const row = page.getByRole('row').filter({ hasText: 'W26-00115' });
  await row.getByRole('button', { name: 'Lift the notice' }).click();

  const dialog = page.getByRole('dialog');

  // "Taken into custody" and "withdrawn" are different facts about the same
  // person, and the register is read months later.
  //
  // The action is "Lift the notice" and not "Cancel", which is what the button
  // beside it does: two buttons named Cancel in one dialog, one of them
  // lifting a wanted notice, is a mis-click waiting for a bad night.
  await expect(dialog).toContainText('W26-00115');
  await dialog.getByLabel('Reason for lifting').selectOption('gripen');
  await dialog.getByRole('button', { name: 'Lift the notice' }).click();

  await expect(page.getByRole('cell', { name: 'W26-00115' })).toHaveCount(0);
});

test('Escape closes the lifting dialog, not the whole interface', async ({ page }) => {
  await openWanted(page);

  const row = page.getByRole('row').filter({ hasText: 'W26-00115' });
  await row.getByRole('button', { name: 'Lift the notice' }).click();

  const dialog = page.getByRole('dialog');
  await expect(dialog).toBeVisible();

  await page.keyboard.press('Escape');

  await expect(dialog).toHaveCount(0);
  await expect(page.getByRole('cell', { name: 'W26-00115' })).toBeVisible();
});

test('draws a notice it may not open as a restricted row', async ({ page }) => {
  await openWanted(page);

  await expect(page.getByText('Restricted record — Contact Internal Affairs')).toBeVisible();
  await expect(page.getByText('Restricted record — Contact Homicide')).toBeVisible();
});

test('renders the wanted tab in Swedish', async ({ page }) => {
  await page.goto('/?locale=sv');

  await page.locator('nav').first().getByRole('button', { name: 'Register' }).click();
  await page.getByRole('button', { name: 'Efterlysningar', exact: true }).click();

  const row = page.getByRole('row').filter({ hasText: 'W26-00115' });

  await expect(row).toContainText('Anhållen i sin frånvaro');
  await expect(row).toContainText('Ska gripas');
  await expect(row).toContainText('Tills den avlyses');
});
