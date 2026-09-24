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
 *   * **Only the decisions this officer may take are offered.** An officer is
 *     not an åklagare, so the anhållande is not drawn — unless nobody playing
 *     the åklagare is signed on, when a supervisor may take it as a stand-in
 *     (7.9.1), labelled and logged as one, and never on their own arrest.
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
  await page.getByRole('button', { name: 'Release', exact: true }).click();

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

test('does not offer a decision this officer may not take', async ({ page }) => {
  await openCustody(page);

  // A26-00041 is this officer's own arrest. The anhållande is the åklagare's,
  // and a supervisor standing in for one may not decide on their own arrest,
  // so the button is not drawn at all; release always is. A häktning from
  // here is a detention with no legal basis and is not drawn either.
  await page.getByRole('button', { name: 'A26-00041' }).click();

  await expect(page.getByRole('button', { name: 'Release', exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: /^Detain/ })).toHaveCount(0);
  await expect(page.getByRole('button', { name: /^Remand/ })).toHaveCount(0);

  // …and says what the chain is waiting on, rather than leaving a gap.
  await expect(page.getByText("Waiting on the prosecutor's decision.")).toBeVisible();
});

test('a prosecutor signing on mid-decision is a decision not taken, not a role problem', async ({
  page,
}) => {
  await openCustody(page);

  await page.getByRole('button', { name: 'A26-00039' }).click();
  await page.getByRole('button', { name: 'File remand application as stand-in' }).click();

  // A prosecutor signs on between the read and the press.
  await page.evaluate(() => {
    (window as unknown as { __fixtureProsecutorOnline?: boolean }).__fixtureProsecutorOnline = true;
  });

  await page
    .getByRole('dialog')
    .getByRole('button', { name: 'File remand application as stand-in' })
    .click();

  const panel = page.getByRole('alert').filter({ hasText: 'This decision was not taken.' });
  await expect(panel).toContainText('This decision was not taken.');
  await expect(panel).toContainText('A prosecutor or judge has signed on');
  await expect(panel).not.toContainText('Discord');

  // Re-read: the stand-in button is gone now that the decision is theirs.
  await expect(
    page.getByRole('button', { name: 'File remand application as stand-in' }),
  ).toHaveCount(0);
});

test('lets a supervisor stand in for the prosecutor, and says so on the record', async ({
  page,
}) => {
  await openCustody(page);

  // Somebody else's arrest, anhållen, with no prosecutor signed on.
  await page.getByRole('button', { name: 'A26-00039' }).click();
  await page.getByRole('button', { name: 'File remand application as stand-in' }).click();

  const dialog = page.getByRole('dialog');
  await expect(dialog).toContainText('No prosecutor is signed on');

  await dialog.getByRole('button', { name: 'File remand application as stand-in' }).click();

  // The chain moved, and the custody log says who decided it and how.
  await expect(page.getByRole('dialog')).toHaveCount(0);
  await expect(
    page.getByText('Häktningsframställan by stand-in (no prosecutor signed on)'),
  ).toBeVisible();

  // The court's decision is next, and this officer holds no stand-in grant
  // for the domare.
  await expect(page.getByRole('button', { name: /^Remand/ })).toHaveCount(0);
});

test('offers the stand-in decision in Swedish', async ({ page }) => {
  await page.goto('/?locale=sv');

  await page.locator('nav').first().getByRole('button', { name: 'Register' }).click();
  await page.getByRole('button', { name: 'Frihetsberövanden', exact: true }).click();
  await page.getByRole('button', { name: 'A26-00039' }).click();

  await page.getByRole('button', { name: 'Lämna häktningsframställan som ersättare' }).click();
  await expect(page.getByRole('dialog')).toContainText('Ingen åklagare är inloggad');
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

  // Picked by name, not typed as an internal id nobody can see.
  await form.getByLabel('Person id').fill('john');
  await page.getByRole('option', { name: /Doe, John/ }).click();
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
  await form.getByLabel('Person id').fill('john');
  await page.getByRole('option', { name: /Doe, John/ }).click();
  await form.getByLabel('Ground').selectOption('efterlyst');
  await form.getByRole('button', { name: 'Record the arrest' }).click();

  // 7.13's auto-resolve. The arrest is what the notice existed to produce, and
  // leaving it live means the next officer to run them gets a red "detain on
  // sight" banner for somebody already in a cell — and the officer after that
  // stops believing the banners.
  await page.getByRole('button', { name: 'Wanted notices', exact: true }).click();
  await expect(page.getByRole('cell', { name: 'W26-00115' })).toHaveCount(0);
});

test('says what somebody is held for, picked from the catalogue', async ({ page }) => {
  await openCustody(page);

  await page.getByRole('button', { name: 'A26-00041' }).click();
  await page.getByRole('button', { name: 'Change charges' }).click();

  // Found by name, ticked, saved: no comma-typed list of catalogue ids.
  await page.getByRole('searchbox', { name: /Find an offence/ }).fill('aggravated');
  await page.getByRole('checkbox', { name: /Aggravated theft/ }).check();
  await page.getByRole('button', { name: 'Save' }).click();

  await expect(page.getByRole('listitem').filter({ hasText: 'Aggravated theft' })).toBeVisible();
});

test('goes straight to booking with the chain already chosen', async ({ page }) => {
  await openCustody(page);

  await page.getByRole('button', { name: 'A26-00041' }).click();
  await page.getByRole('button', { name: 'Book this person in' }).click();

  const custody = page.getByRole('combobox', { name: /Custody/ });
  await expect(custody.locator('option:checked')).toContainText('A26-00041');
});
