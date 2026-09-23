import { expect, test } from '@playwright/test';
import type { Locator, Page } from '@playwright/test';

/**
 * ALPR against the mock bridge (spec 7.18): plate reads, and the hotlist that
 * turns one into a banner.
 *
 * The read itself is never the secret -- a camera saw a car. What must never
 * reach a session that did not create it is that the car is *watched*, so the
 * fixture seeds one silent hotlist entry created by another session and a
 * real read against it, the same way `seesSilent` is exercised server-side:
 * the read stays on the list and the fact that it is a hit does not.
 */

async function openAlpr(page: Page, locale?: string): Promise<void> {
  const swedish = locale === 'sv';

  // No `locale` argument still exercises English explicitly. The bare
  // default (no `?locale=` at all) now resolves from the session's
  // configured language, which the shell tests cover.
  await page.goto(`/?locale=${locale ?? 'en'}`);
  await page
    .locator('nav')
    .first()
    .getByRole('button', { name: swedish ? 'Ledningscentral' : 'Dispatch' })
    .click();
  await page
    .getByRole('button', { name: swedish ? 'Skyltavläsningar' : 'Plate reads', exact: true })
    .click();
}

/**
 * Scoped to the hotlist panel, so a plate is not also matched in the reads
 * table beside it. `Dispatch.svelte` wraps the whole console in a `<section>`
 * of its own, so the filter matches that ancestor too -- `.last()` is what
 * makes it the panel rather than the console (see `dispatch.spec.ts`).
 */
function hotlistPanel(page: Page, heading: string): Locator {
  return page
    .locator('section')
    .filter({ has: page.getByRole('heading', { name: heading, exact: true }) })
    .last();
}

test('lists plate reads within the default window', async ({ page }) => {
  await openAlpr(page);

  await expect(page.getByRole('row').filter({ hasText: '6ABC123' })).toBeVisible();
  await expect(page.getByRole('row').filter({ hasText: '4JKL556' })).toBeVisible();
});

test('marks a hotlist hit and names the reason', async ({ page }) => {
  await openAlpr(page);

  const row = page.getByRole('row').filter({ hasText: '6ABC123' });
  await expect(row).toContainText('Stolen vehicle');
});

test('never discloses a covert watch this session may not see', async ({ page }) => {
  await openAlpr(page);

  // The read against the covert entry is real in the fixture, but this
  // session did not create the watch, so it comes back masked exactly as
  // `seesSilent` masks it server-side.
  const row = page.getByRole('row').filter({ hasText: '9QRS231' });
  await expect(row).toBeVisible();
  await expect(row).not.toContainText('Wanted person');
});

test('shows a hit banner and can dismiss it', async ({ page }) => {
  await openAlpr(page);

  const banner = page.getByText('6ABC123 — Stolen vehicle');
  await expect(banner).toBeVisible();

  await page.getByRole('button', { name: 'Dismiss' }).first().click();
  await expect(banner).toHaveCount(0);
});

test('lists the hotlist, and withholds a silent entry it did not create', async ({ page }) => {
  await openAlpr(page);

  const panel = hotlistPanel(page, 'Hotlist');

  await expect(panel.getByText('7XYZ890', { exact: true })).toBeVisible();
  await expect(panel.getByText('9QRS231', { exact: true })).toHaveCount(0);
});

test('adds a plate to the hotlist', async ({ page }) => {
  await openAlpr(page);

  await page.getByRole('button', { name: 'Add plate' }).click();

  const form = page.locator('form').filter({ hasText: 'Reason' });
  await form.getByLabel('Plate').fill('5TTT909');
  await form.getByLabel('Reason').selectOption('bolo');
  await form.getByRole('button', { name: 'Add to hotlist' }).click();

  await expect(hotlistPanel(page, 'Hotlist').getByText('5TTT909', { exact: true })).toBeVisible();
});

test('asks before removing a plate from the hotlist', async ({ page }) => {
  await openAlpr(page);

  await page.getByRole('button', { name: 'Remove plate' }).first().click();

  const dialog = page.getByRole('dialog');
  await expect(dialog).toContainText('6ABC123');

  await dialog.getByRole('button', { name: 'Remove plate' }).click();

  await expect(hotlistPanel(page, 'Hotlist').getByText('6ABC123', { exact: true })).toHaveCount(0);
});

test('Escape closes the removal dialog, not the whole interface', async ({ page }) => {
  await openAlpr(page);

  await page.getByRole('button', { name: 'Remove plate' }).first().click();

  const dialog = page.getByRole('dialog');
  await expect(dialog).toBeVisible();

  await page.keyboard.press('Escape');

  await expect(dialog).toHaveCount(0);
  await expect(page.getByRole('heading', { name: 'Hotlist', exact: true })).toBeVisible();
});

test('renders the ALPR tab in Swedish', async ({ page }) => {
  await openAlpr(page, 'sv');

  await expect(page.getByRole('heading', { name: 'Skyltavläsningar' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Bevakningslista' })).toBeVisible();
});
