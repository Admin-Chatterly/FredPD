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
  await page.goto('/?locale=en');

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

test('draws the chain as decisions, in order, with the ground each rested on', async ({
  page,
}) => {
  await openCustody(page);

  await page.getByRole('button', { name: 'A26-00039' }).click();

  await expect(page.getByRole('heading', { name: 'Decisions' })).toBeVisible();

  // The rows name the *act*, not the person's state: "Gripen / Anhållen" under
  // a heading of "Decisions" reads as a list of conditions, not of decisions.
  // Exact: "Häktning" is a prefix of "Häktningsframställan", and both are rows.
  const remand = page
    .getByRole('listitem')
    .filter({ has: page.getByText('Häktning (remand by the court)') });
  await expect(remand).toContainText('Not taken');

  // The ground is the part quoted afterwards, and it comes from the server as
  // `gripandeGrund` — a field this screen once read as a bare `grund`, which
  // meant it rendered nothing at all in game while every test passed.
  const arrest = page.getByRole('listitem').filter({ hasText: 'Gripande' });
  await expect(arrest).toContainText('Risk of flight');
});

test('shows the release ground, which was stored and never drawn', async ({ page }) => {
  await openCustody(page);

  await page.getByLabel('Currently held only').uncheck();
  await page.getByRole('button', { name: 'Search' }).click();
  await page.getByRole('button', { name: 'A26-00038' }).click();

  const release = page.getByRole('listitem').filter({ hasText: 'Frigivande' });
  await expect(release).toContainText('Not detained by the prosecutor');
});

test('stops the clocks when somebody is released', async ({ page }) => {
  await openCustody(page);

  await page.getByLabel('Currently held only').uncheck();
  await page.getByRole('button', { name: 'Search' }).click();

  // A26-00038 was arrested 200 hours ago and released 194 hours ago. Both RB
  // clocks would otherwise still be running and long past, so the history list
  // drew a breach warning — and the red banner — against somebody already out.
  const row = page.getByRole('row').filter({ hasText: 'A26-00038' });
  await expect(row).not.toContainText('Overdue');

  await page.getByRole('button', { name: 'A26-00038' }).click();
  await expect(page.getByText('No deadline is running.')).toBeVisible();
  await expect(page.getByRole('alert')).toHaveCount(0);
});

test('marks a deadline that is close but not yet breached', async ({ page }) => {
  await openCustody(page);

  // A26-00040 is inside the warning window. Before this it rendered in plain
  // ink, identical to a row with three days left — on the board a supervisor
  // watches precisely to catch the row that is about to breach.
  const row = page.getByRole('row').filter({ hasText: 'A26-00040' });
  await expect(row).toContainText('Due soon');
});

test('says which deadline needs attention, not merely that one does', async ({ page }) => {
  await openCustody(page);

  await page.getByRole('button', { name: 'A26-00039' }).click();

  // "A statutory deadline needs attention" does not tell an officer whether to
  // ring the prosecutor or the court.
  await expect(page.getByRole('alert')).toContainText('Remand application (RB 24:12)');
  await expect(page.getByRole('alert')).toContainText('has passed');
});

test('names the officer who wrote a custody log entry, not their account id', async ({ page }) => {
  await openCustody(page);

  await page.getByRole('button', { name: 'A26-00041' }).click();

  // An 18-digit Discord snowflake told an officer nothing and put an account
  // identifier on the face of a record a defence lawyer reads.
  await expect(page.getByRole('cell', { name: 'Berg (1-ADAM-12)' })).toBeVisible();
});

test('Escape closes the confirmation, not the whole interface', async ({ page }) => {
  await openCustody(page);

  await page.getByRole('button', { name: 'A26-00041' }).click();
  await page.getByRole('button', { name: 'Detain (prosecutor)' }).click();

  const dialog = page.getByRole('dialog');
  await expect(dialog).toBeVisible();

  // `main.ts` listens for Escape on `window` and asks the client to close the
  // NUI. Inside a dialog about a detention that discarded the open record and
  // the chosen ground; 6.4 wants Escape to close the dialog.
  await page.keyboard.press('Escape');

  await expect(dialog).toHaveCount(0);
  // The record is still open behind it, and the shell is still there.
  await expect(page.getByRole('heading', { name: 'Decisions' })).toBeVisible();
});

test('asks for a ground rather than offering "Any"', async ({ page }) => {
  await openCustody(page);

  await page.getByRole('button', { name: 'A26-00041' }).click();
  await page.getByRole('button', { name: 'Release', exact: true }).click();

  // The server requires this field. An empty option labelled "Any" read as a
  // filter default and invited a refusal the officer had done nothing to earn.
  // Scoped to the dialog: the status filter and the log-kind picker are
  // comboboxes too.
  await expect(page.getByRole('dialog').getByRole('combobox')).toContainText('Choose a ground');
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
  await page.getByRole('button', { name: 'Frihetsberövanden', exact: true }).click();

  await expect(page.getByRole('button', { name: 'A26-00041' })).toBeVisible();

  const row = page.getByRole('row').filter({ hasText: 'A26-00039' });
  await expect(row).toContainText('Överskriden');

  await page.getByRole('button', { name: 'A26-00041' }).click();

  await expect(page.getByRole('heading', { name: 'Arrestjournal' })).toBeVisible();
  await expect(page.getByText('Ännu inte underrättad om misstanke.')).toBeVisible();

  await expect(page.getByText('Skyddad post — Kontakta Internutredningen')).toBeVisible();
});

test('records a gripande, which is how a chain starts at all', async ({ page }) => {
  await openCustody(page);

  // `frihet.gripande` had no caller anywhere in the interface: every decision
  // *in* a chain could be taken and there was no way to begin one, so in game
  // nobody could ever be booked in.
  await page.getByRole('button', { name: 'Record an arrest' }).click();

  const form = page.locator('form').filter({ hasText: 'Where' });

  await form.getByLabel('Person id').fill('1');
  await form.getByLabel('Ground').selectOption('pa_bar_garning');
  await form.getByLabel('Where').fill('Kvarngatan 3B, outside the stairwell');
  await form.getByRole('button', { name: 'Record the arrest' }).click();

  await expect(page.getByRole('heading', { name: /^A26-/ })).toBeVisible();

  // The place is drawn on the chain. The server has stored it since the module
  // landed and nothing rendered it.
  const arrest = page.getByRole('listitem').filter({ hasText: 'Gripande' });
  await expect(arrest).toContainText('Kvarngatan 3B, outside the stairwell');
});

test('an arrest takes down the wanted notice that asked for it', async ({ page }) => {
  await page.goto('/?locale=en');
  await page.locator('nav').first().getByRole('button', { name: 'Records' }).click();

  // John Doe (person 1) is anhållen i sin frånvaro.
  await page.getByRole('button', { name: 'Wanted notices', exact: true }).click();
  await expect(page.getByRole('row').filter({ hasText: 'W26-00115' })).toContainText(
    'Detain on sight',
  );

  await page.getByRole('button', { name: 'Custody', exact: true }).click();
  await page.getByRole('button', { name: 'Record an arrest' }).click();

  const form = page.locator('form').filter({ hasText: 'Where' });
  await form.getByLabel('Person id').fill('1');
  await form.getByLabel('Ground').selectOption('efterlyst');
  await form.getByRole('button', { name: 'Record the arrest' }).click();

  // 7.13's auto-resolve. The arrest is what the notice existed to produce, and
  // leaving it live means the next officer to run them gets a red "detain on
  // sight" banner for somebody already in a cell — and the officer after that
  // stops believing the banners.
  await page.getByRole('button', { name: 'Wanted notices', exact: true }).click();
  await expect(page.getByRole('cell', { name: 'W26-00115' })).toHaveCount(0);
});
