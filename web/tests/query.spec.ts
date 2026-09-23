import { expect, test } from '@playwright/test';
import type { Page } from '@playwright/test';

/**
 * The unified query and its hot-file hits (spec 7.2).
 *
 * This is the front half of M2's exit criterion — "query → hit → arrest →
 * report → approval" — and until this screen existed the three routes behind
 * it had no caller at all: the registers were reachable a tab at a time, and
 * the one box an officer actually types into was not there.
 *
 * Three of these are the reason it is worth its own screen rather than a
 * fourth register tab:
 *
 *   * **A hit arrives unconfirmed and says so.** Confirming is a second,
 *     deliberate act that the log records against the query that raised it,
 *     because an officer who acts on a lead has done something a department
 *     may ask about later.
 *   * **The confirmation can conclude "not confirmed".** A step with one
 *     button is a rubber stamp.
 *   * **A query that reaches a restricted record is refused until a reason is
 *     given, and the refusal is actionable** — never a count of what was
 *     withheld, which would be the disclosure the refusal exists to prevent.
 */

async function openQuery(page: Page): Promise<void> {
  await page.goto('/?locale=en');

  await page.locator('nav').first().getByRole('button', { name: 'Records' }).click();
}

test('is the tab Records opens on', async ({ page }) => {
  await openQuery(page);

  // What an officer reaches for first: one box for a name, a plate or a
  // serial. The registers behind it are for working a record once found.
  await expect(page.getByLabel('Search', { exact: false }).first()).toBeVisible();
});

test('runs a name and says which registers answered', async ({ page }) => {
  await openQuery(page);

  await page.getByRole('textbox', { name: 'Search' }).fill('petrov');
  await page.getByRole('button', { name: 'Search', exact: true }).click();

  await expect(page.getByText(/Ran as .* against/)).toContainText('Name index');
});

test('raises a wanted hit, unconfirmed, and says which it is', async ({ page }) => {
  await openQuery(page);

  await page.getByRole('textbox', { name: 'Search' }).fill('john');
  await page.getByRole('button', { name: 'Search', exact: true }).click();

  const hit = page.getByRole('alert').filter({ hasText: 'WANTED' });

  await expect(hit).toContainText('detained in absentia');
  // In words. A lead and a confirmed record are different things to act on.
  await expect(hit).toContainText('Unconfirmed hit');
});

test('records a confirmation, and can conclude that it was not confirmed', async ({ page }) => {
  await openQuery(page);

  await page.getByRole('textbox', { name: 'Search' }).fill('john');
  await page.getByRole('button', { name: 'Search', exact: true }).click();
  await page.getByRole('button', { name: 'Confirm the hit' }).click();

  const dialog = page.getByRole('dialog');

  // The outcome is a choice. A confirmation step that can only say "yes" is
  // not a check on anything.
  await expect(dialog.getByLabel('Outcome')).toContainText('No answer from the holding agency');

  await dialog.getByLabel('Outcome').selectOption('not_confirmed');
  await dialog.getByRole('button', { name: 'Confirm the hit' }).click();

  await expect(page.getByRole('status')).toContainText('Not confirmed');
});

test('asks what a confirmation was confirmed against', async ({ page }) => {
  await openQuery(page);

  await page.getByRole('textbox', { name: 'Search' }).fill('john');
  await page.getByRole('button', { name: 'Search', exact: true }).click();
  await page.getByRole('button', { name: 'Confirm the hit' }).click();

  // "It came back confirmed" is not an answer to "confirmed against what?",
  // and the server requires one of the two.
  await expect(page.getByRole('dialog')).toContainText('Say what it was confirmed against');
});

test('refuses a query that reaches a restricted record, and offers the fix', async ({ page }) => {
  await openQuery(page);

  // "doe" reaches the third Doe, who is restricted.
  await page.getByRole('textbox', { name: 'Search' }).fill('doe');
  await page.getByRole('button', { name: 'Search', exact: true }).click();

  const panel = page.getByRole('alert');

  await expect(panel).toContainText('Some of what matched is restricted');
  // Never "3 records hidden": the count is not sent, and asking for it would
  // be asking the server to disclose what it withheld.
  await expect(panel).not.toContainText(/\d+ record/);

  await panel.getByRole('button', { name: 'Give a reason' }).click();
  await expect(page.getByRole('textbox', { name: 'Reason' })).toBeFocused();
});

test('runs with a reason and then returns the restricted row as a stub', async ({ page }) => {
  await openQuery(page);

  await page.getByRole('textbox', { name: 'Search' }).fill('doe');
  await page.getByRole('textbox', { name: 'Reason' }).fill('Suspect in K26-00512');
  await page.getByRole('button', { name: 'Search', exact: true }).click();

  // 4.5: the reader may be told the record exists and who to ring about it.
  await expect(page.getByText('Restricted record — Contact Homicide')).toBeVisible();
});

test('logs the query that found nothing', async ({ page }) => {
  await openQuery(page);

  await page.getByRole('button', { name: 'My recent queries' }).click();

  // The log answers "who has been looking up their ex-partner", and a query
  // that matched nothing is part of that answer.
  const row = page.getByRole('row').filter({ hasText: 'nilsson' });

  await expect(row).toContainText('0');
});

test('says whether a hit a query raised was ever confirmed', async ({ page }) => {
  await openQuery(page);

  await page.getByRole('button', { name: 'My recent queries' }).click();

  // Acting on an unconfirmed hit is the thing the log exists to make
  // answerable afterwards.
  const row = page.getByRole('row').filter({ hasText: '47ANX291' });

  await expect(row).toContainText('1 of 1');
});

test('renders the query tab in Swedish', async ({ page }) => {
  await page.goto('/?locale=sv');

  await page.locator('nav').first().getByRole('button', { name: 'Register' }).click();

  await page.getByRole('textbox', { name: 'Sök' }).fill('john');
  await page.getByRole('button', { name: 'Sök', exact: true }).click();

  await expect(page.getByRole('alert').first()).toContainText('EFTERLYST');
});
