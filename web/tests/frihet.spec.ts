import { expect, test } from '@playwright/test';
import type { Page } from '@playwright/test';

/**
 * The frihetsberövande chain against the mock bridge (spec 7.9, 15).
 *
 * Three of these are the reason the screen exists, and none of them is about a
 * button working:
 *
 *   * **An overdue statutory deadline is visible as overdue.** A26-00039 has
 *     been anhållen for four days with no häktningsframställan, so RB 24:12's
 *     noon is long past. If that row reads like every other row, the screen has
 *     failed at the one thing it is for.
 *   * **A refusal says which kind of refusal it is.** An officer is not an
 *     åklagare, so `anhållande` comes back `wrong_capacity` — "that decision is
 *     not yours to take", never a message about Discord roles. And a häktning
 *     from `gripen` is `out_of_order`, not the validator's "not an allowed
 *     value": the status is real, it is the step from it that is not.
 *   * **The countdown counts.** It ticks from the server's `remaining`, not
 *     from its `at`, so this asserts the number moves rather than asserting any
 *     particular number — the fixture's clocks are relative and a fixed
 *     assertion would be a test that rots.
 *
 * The rest is the frame: the tab opens, the chain draws in order, the custody
 * log takes an entry, and it all reads in Swedish.
 */

/** Opens Records and switches to the custody tab. */
async function openCustody(page: Page): Promise<void> {
  await page.goto('/');

  await page.locator('nav').first().getByRole('button', { name: 'Records' }).click();
  await page.getByRole('button', { name: 'Custody', exact: true }).click();
}

test('lists everybody currently held, and not the released', async ({ page }) => {
  await openCustody(page);

  await expect(page.getByRole('button', { name: 'A26-00041' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'A26-00039' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'A26-00040' })).toBeVisible();

  // A26-00038 was released. "Currently held" is the default and means it.
  await expect(page.getByRole('button', { name: 'A26-00038' })).toHaveCount(0);
});

test('shows a released detention once the filter is cleared', async ({ page }) => {
  await openCustody(page);

  await page.getByLabel('Currently held only').uncheck();
  await page.getByRole('button', { name: 'Search' }).click();

  await expect(page.getByRole('button', { name: 'A26-00038' })).toBeVisible();
});

test('marks an overdue RB 24:12 deadline as overdue, in words', async ({ page }) => {
  await openCustody(page);

  const row = page.getByRole('row').filter({ hasText: 'A26-00039' });

  // In words as well as in colour: colour alone is not a signal every officer
  // receives, and this is the row where missing it is an unlawful detention.
  await expect(row).toContainText('Overdue');
  await expect(row).toContainText('Overdue by');
});

test('draws the chain in order, with who decided and when', async ({ page }) => {
  await openCustody(page);

  await page.getByRole('button', { name: 'A26-00039' }).click();

  await expect(page.getByRole('heading', { name: 'Decisions' })).toBeVisible();

  // Arrested and detained by the prosecutor; the two later stages have not
  // happened and say so rather than rendering an empty row.
  const chain = page.getByRole('listitem').filter({ hasText: 'Remanded in custody' });
  await expect(chain).toContainText('Not taken');
});

test('counts down, rather than printing a number the server sent once', async ({ page }) => {
  await openCustody(page);

  await page.getByRole('button', { name: 'A26-00041' }).click();

  const deadline = page.getByText(/remaining$/).first();
  const before = await deadline.textContent();

  // The tick is one second. Asserting the text *changes* rather than what it
  // changes to: the fixture's clocks are relative to when it is read, so a
  // fixed expectation here would pass today and rot.
  await page.waitForTimeout(2200);

  await expect(deadline).not.toHaveText(before ?? '');
});

test('refuses an anhållande as not this officer’s decision to take', async ({ page }) => {
  await openCustody(page);

  await page.getByRole('button', { name: 'A26-00041' }).click();

  // 6.4: a legal action asks first, with a verb label.
  await page.getByRole('button', { name: 'Detain (prosecutor)' }).click();
  await expect(page.getByText(/Anhållande is the prosecutor/)).toBeVisible();

  await page.getByLabel('Ground').selectOption('flyktfara');
  await page.getByRole('button', { name: 'Detain (prosecutor)' }).click();

  const panel = page.getByRole('alert');

  // The capacity refusal reads as itself. An officer told "your Discord roles
  // do not grant access" goes and asks for a rank; the truth is that this
  // decision belongs to a prosecutor whatever rank they hold.
  await expect(panel).toContainText('That decision is not yours to take.');
  await expect(panel).not.toContainText('wrong_capacity');
});

test('does not offer a decision the chain has not reached', async ({ page }) => {
  await openCustody(page);

  await page.getByRole('button', { name: 'A26-00041' }).click();

  // Somebody gripen can be anhållen or released. A häktning from here is a
  // detention with no legal basis, so the button is not drawn at all.
  await expect(page.getByRole('button', { name: 'Detain (prosecutor)' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Release', exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Remand in custody' })).toHaveCount(0);
});

test('records the RB 24:9 notice once, and stops offering it', async ({ page }) => {
  await openCustody(page);

  await page.getByRole('button', { name: 'A26-00041' }).click();

  await expect(page.getByText('Not yet notified of suspicion.')).toBeVisible();
  await page.getByRole('button', { name: 'Record notice of suspicion' }).click();

  await expect(page.getByText(/Notified of suspicion \(RB 24:9\)/)).toBeVisible();
  await expect(page.getByRole('button', { name: 'Record notice of suspicion' })).toHaveCount(0);
});

test('adds an entry to the custody log', async ({ page }) => {
  await openCustody(page);

  await page.getByRole('button', { name: 'A26-00041' }).click();

  await page.getByLabel('Entry').selectOption('forsvarare');
  await page.getByLabel('Note').fill('Advokat Lindqvist kom 14:10.');
  await page.getByRole('button', { name: 'Add to the custody log' }).click();

  await expect(page.getByRole('cell', { name: 'Advokat Lindqvist kom 14:10.' })).toBeVisible();
  await expect(page.getByRole('cell', { name: 'Defence counsel' })).toBeVisible();
});

test('shows the sentencing range the server computed', async ({ page }) => {
  await openCustody(page);

  await page.getByRole('button', { name: 'A26-00041' }).click();

  // 6 to 72 months arrives computed (BrB 26:2 is the server's arithmetic).
  await expect(page.getByText('at least 6 months, up to 6 years')).toBeVisible();
});

test('draws a detention it may not open as a restricted row', async ({ page }) => {
  await openCustody(page);

  // Two stubs, neither carrying an id (4.5). One would not catch a list keyed
  // by id; two collide on `undefined` and the table refuses to render.
  await expect(page.getByText('Restricted record — Contact Internal Affairs')).toBeVisible();
  await expect(page.getByText('Restricted record — Contact Homicide')).toBeVisible();

  await expect(page.getByRole('button', { name: 'A26-00041' })).toBeVisible();
});

test('renders the custody tab in Swedish', async ({ page }) => {
  await page.goto('/?locale=sv');

  await page.locator('nav').first().getByRole('button', { name: 'Register' }).click();
  await page.getByRole('button', { name: 'Frihetsberövande', exact: true }).click();

  await expect(page.getByRole('button', { name: 'A26-00041' })).toBeVisible();

  const row = page.getByRole('row').filter({ hasText: 'A26-00039' });
  await expect(row).toContainText('Överskriden');

  await page.getByRole('button', { name: 'A26-00041' }).click();

  await expect(page.getByRole('heading', { name: 'Arrestjournal' })).toBeVisible();
  await expect(page.getByText('Ännu inte underrättad om misstanke.')).toBeVisible();

  await expect(page.getByText('Skyddad post — Kontakta Internutredningen')).toBeVisible();
});
