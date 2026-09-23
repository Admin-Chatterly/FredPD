import { expect, test } from '@playwright/test';
import type { Page } from '@playwright/test';

/**
 * Spaningsuppdrag against the mock bridge (spec 7.13).
 *
 * The two tests worth reading are about volume, not about buttons.
 *
 * A lookout is patrol work: any officer may raise one, and that is deliberate,
 * because a department where a lookout needed command approval would simply
 * not use it and the sightings would live in radio traffic where nothing can
 * search them. The cost of that openness is that a lookout must never be as
 * loud as a prosecutor's decision to detain — only priority 1 reaches a
 * banner, the officer raising one is told so before they do it, and nothing
 * here ever reads as "detain on sight".
 *
 * An officer shown a red banner for every "have a look for this van" learns
 * within a shift that red banners are usually nothing, and then misses the one
 * that was a person with a knife.
 */

async function openLookouts(page: Page): Promise<void> {
  await page.goto('/?locale=en');

  await page.locator('nav').first().getByRole('button', { name: 'Records' }).click();
  await page.getByRole('button', { name: 'Lookouts', exact: true }).click();
}

test('lists the running lookouts, and not the closed', async ({ page }) => {
  await openLookouts(page);

  await expect(page.getByRole('button', { name: 'S26-00042' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'S26-00041' })).toBeVisible();

  await expect(page.getByRole('button', { name: 'S26-00033' })).toHaveCount(0);
});

test('draws the banner level only where the server gave one', async ({ page }) => {
  await openLookouts(page);

  // Priority 1 is the only level that reaches a banner, and it is drawn from
  // the server's `bannerFor` rather than from the priority read here.
  const loud = page.getByRole('row').filter({ hasText: 'S26-00042' });
  await expect(loud).toContainText('Alert');

  const routine = page.getByRole('row').filter({ hasText: 'S26-00041' });
  await expect(routine).not.toContainText('Alert');
});

test('never says detain on sight', async ({ page }) => {
  await openLookouts(page);

  // That treatment belongs to an efterlysning and to nothing else. A lookout
  // that could borrow it would be an officer's own decision wearing a
  // prosecutor's clothes.
  await expect(page.getByText('Detain on sight')).toHaveCount(0);

  await page.getByRole('button', { name: 'S26-00042' }).click();
  await expect(page.getByText('A lookout, not a wanted notice. Report the sighting.')).toBeVisible();
});

test('carries a lookout with a description and no record behind it', async ({ page }) => {
  await openLookouts(page);

  // The commonest lookout there is, and the case a foreign key cannot express.
  const row = page.getByRole('row').filter({ hasText: 'S26-00041' });

  await expect(row).toContainText('Silver estate, no plate seen, three occupants');
});

test('warns before a lookout is raised at priority 1, not after', async ({ page }) => {
  await openLookouts(page);

  await page.getByRole('button', { name: 'Raise a lookout' }).click();

  const form = page.locator('form').filter({ hasText: 'Area' });

  await expect(form).not.toContainText('raises a banner for every officer');

  await form.getByLabel('Priority').selectOption('1');
  await expect(form).toContainText('raises a banner for every officer');
});

test('drops the record id when the lookout names no record', async ({ page }) => {
  await openLookouts(page);

  await page.getByRole('button', { name: 'Raise a lookout' }).click();

  const form = page.locator('form').filter({ hasText: 'Area' });

  await expect(form.getByLabel('Record id')).toBeVisible();

  // `other` means there is no record to point at. An id alongside it would be
  // an id into nothing, and the server refuses it with `not_allowed`.
  await form.getByLabel('Looking for').selectOption('other');
  await expect(form.getByLabel('Record id')).toHaveCount(0);
});

test('raises a lookout on a description alone', async ({ page }) => {
  await openLookouts(page);

  await page.getByRole('button', { name: 'Raise a lookout' }).click();

  const form = page.locator('form').filter({ hasText: 'Area' });

  await form.getByLabel('Looking for').selectOption('other');
  await form.getByRole('textbox', { name: 'Description' }).fill('Dark van, ladder on the roof');
  await form.getByLabel('Reason').selectOption('iakttagelse');
  await form.getByRole('button', { name: 'Raise a lookout' }).click();

  await expect(
    page.getByRole('row').filter({ hasText: 'Dark van, ladder on the roof' }),
  ).toBeVisible();
});

test('renders the expiry in this decade', async ({ page }) => {
  await openLookouts(page);

  // `UNIX_TIMESTAMP` is seconds. Read as milliseconds this said 1970.
  const row = page.getByRole('row').filter({ hasText: 'S26-00042' });

  await expect(row).toContainText(String(new Date().getFullYear()));
});

test('asks why a lookout is being closed', async ({ page }) => {
  await openLookouts(page);

  await page.getByRole('button', { name: 'S26-00042' }).click();
  await page.getByRole('button', { name: 'Close the lookout' }).click();

  const dialog = page.getByRole('dialog');

  await expect(dialog).toContainText('S26-00042');
  await dialog.getByLabel('Reason for closing').selectOption('omhandertaget');
  await dialog.getByRole('button', { name: 'Close the lookout' }).click();

  await expect(page.getByText('Vehicle impounded')).toBeVisible();
});

test('Escape closes the dialog, not the whole interface', async ({ page }) => {
  await openLookouts(page);

  await page.getByRole('button', { name: 'S26-00042' }).click();
  await page.getByRole('button', { name: 'Close the lookout' }).click();

  const dialog = page.getByRole('dialog');
  await expect(dialog).toBeVisible();

  await page.keyboard.press('Escape');

  await expect(dialog).toHaveCount(0);
  await expect(page.getByRole('heading', { name: 'S26-00042' })).toBeVisible();
});

test('draws a lookout it may not open as a restricted row', async ({ page }) => {
  await openLookouts(page);

  await expect(page.getByText('Restricted record — Contact Internal Affairs')).toBeVisible();
  await expect(page.getByText('Restricted record — Contact Homicide')).toBeVisible();
});

test('loads the next page of lookouts with the load-more control', async ({ page }) => {
  // `?pageSize=1` walks a genuine multi-page flow off the two live fixture
  // rows without needing fifty of them (spec 12.2).
  await page.goto('/?pageSize=1&locale=en');
  await page.locator('nav').first().getByRole('button', { name: 'Records' }).click();
  await page.getByRole('button', { name: 'Lookouts', exact: true }).click();

  await expect(page.getByRole('button', { name: 'S26-00042' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'S26-00041' })).toHaveCount(0);

  await page.getByRole('button', { name: 'Load more' }).click();

  await expect(page.getByRole('button', { name: 'S26-00041' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Load more' })).toHaveCount(0);
});

test('searching again drops the pages already loaded', async ({ page }) => {
  await page.goto('/?pageSize=1&locale=en');
  await page.locator('nav').first().getByRole('button', { name: 'Records' }).click();
  await page.getByRole('button', { name: 'Lookouts', exact: true }).click();

  await page.getByRole('button', { name: 'Load more' }).click();
  await expect(page.getByRole('button', { name: 'S26-00041' })).toBeVisible();

  // Widening the filter and searching again is a fresh first page, not a
  // third page appended to what load-more already fetched.
  await page.getByLabel('Include closed lookouts').check();
  await page.getByRole('button', { name: 'Search' }).click();

  await expect(page.getByRole('button', { name: 'S26-00042' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'S26-00041' })).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'S26-00033' })).toHaveCount(0);
});

test('renders the lookout tab in Swedish', async ({ page }) => {
  await page.goto('/?locale=sv');

  await page.locator('nav').first().getByRole('button', { name: 'Register' }).click();
  await page.getByRole('button', { name: 'Spaningsuppdrag', exact: true }).click();

  await expect(page.getByRole('button', { name: 'S26-00042' })).toBeVisible();
  await page.getByRole('button', { name: 'S26-00042' }).click();

  await expect(
    page.getByText('Spaningsuppdrag, inte efterlysning. Rapportera iakttagelsen.'),
  ).toBeVisible();
  await expect(page.getByText('Skyddad post — Kontakta Internutredningen')).toBeVisible();
});
