import { expect, test } from '@playwright/test';
import type { Page } from '@playwright/test';

/**
 * Tvångsmedel against the mock bridge (spec 7.12).
 *
 * Three of these are the reason the screen exists:
 *
 *   * **A revoked measure reads as revoked, in words.** `HasSearchWarrant`
 *     answers `false` for it and a door stays shut; an officer standing at
 *     that door has to be told the same thing and told *why*, because
 *     "expired", "not yet in force" and "a prosecutor revoked it this morning"
 *     are three different conversations.
 *   * **A measure that is not this officer's to decide says so.** A
 *     kroppsbesiktning reaches inside somebody's body and needs a prosecutor.
 *     The refusal is `wrong_capacity`, and it must not read as a Discord role
 *     problem.
 *   * **Execution is a record, not a state change.** RB allows a husrannsakan
 *     to be resumed, so a measure stays valid after it is carried out.
 */

async function openMeasures(page: Page): Promise<void> {
  await page.goto('/');

  await page.locator('nav').first().getByRole('button', { name: 'Records' }).click();
  await page.getByRole('button', { name: 'Coercive measures', exact: true }).click();
}

test('lists the measures in force, and not the ones that are not', async ({ page }) => {
  await openMeasures(page);

  await expect(page.getByRole('button', { name: 'W26-00114' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'W26-00108' })).toBeVisible();

  // W26-00110 was revoked. "In force only" is the default and means it.
  await expect(page.getByRole('button', { name: 'W26-00110' })).toHaveCount(0);
});

test('says which way a measure stopped authorising anything', async ({ page }) => {
  await openMeasures(page);

  await page.getByLabel('In force only').uncheck();
  await page.getByRole('button', { name: 'Search' }).click();
  await page.getByRole('button', { name: 'W26-00110' }).click();

  // Not merely "not valid". An officer at a door needs to know a prosecutor
  // revoked this one, which is a different fact from it having lapsed.
  await expect(page.getByRole('alert')).toContainText('Revoked');
});

test('renders the validity window in this decade', async ({ page }) => {
  await openMeasures(page);

  await page.getByRole('button', { name: 'W26-00114' }).click();

  // The repo selects through `UNIX_TIMESTAMP`, which is seconds. Every screen
  // used to read that as milliseconds, so a measure decided this morning
  // rendered as 1970 — in game only, because the fixtures sent ISO strings.
  // The fixture now sends what the server sends, and this is what would have
  // caught it.
  const year = String(new Date().getFullYear());

  await expect(page.getByText('In force from').locator('xpath=following-sibling::dd')).toContainText(
    year,
  );
});

test('refuses a bodily examination as not this officer’s decision', async ({ page }) => {
  await openMeasures(page);

  await page.getByRole('button', { name: 'Record a decision' }).click();

  const form = page.locator('form').filter({ hasText: 'Record id' });

  await form.getByLabel('Measure').selectOption('kroppsbesiktning');
  await form.getByLabel('Record id').fill('2');
  await form.getByLabel('Ground').selectOption('skalig_misstanke');
  await form.getByRole('button', { name: 'Record a decision' }).click();

  const panel = page.getByRole('alert');

  await expect(panel).toContainText('That decision is not yours to take.');
  await expect(panel).not.toContainText('wrong_capacity');
});

test('does not offer a target the measure cannot be aimed at', async ({ page }) => {
  await openMeasures(page);

  await page.getByRole('button', { name: 'Record a decision' }).click();

  const form = page.locator('form').filter({ hasText: 'Record id' });
  const target = form.getByLabel('Directed at');

  // A husrannsakan is directed at a place. Pointing one at a person is how a
  // decision to search a flat ends up authorising a search of whoever is
  // standing in it — the server refuses it, and the form does not offer it.
  await form.getByLabel('Measure').selectOption('husrannsakan_reell');
  await expect(target).not.toContainText('Person');

  // And the mirror image: a search of the person is aimed at one.
  await form.getByLabel('Measure').selectOption('kroppsvisitation');
  await expect(target).toContainText('Person');
  await expect(target).not.toContainText('Address');
});

test('decides a measure and opens it', async ({ page }) => {
  await openMeasures(page);

  await page.getByRole('button', { name: 'Record a decision' }).click();

  const form = page.locator('form').filter({ hasText: 'Record id' });

  await form.getByLabel('Measure').selectOption('husrannsakan_reell');
  await form.getByLabel('Record id').fill('41');
  await form.getByLabel('Named as').fill('Sandstensvägen 7');
  await form.getByLabel('Ground').selectOption('sakra_bevis');
  await form.getByRole('button', { name: 'Record a decision' }).click();

  await expect(page.getByRole('heading', { name: /^W26-/ })).toBeVisible();
  await expect(page.getByText('Not yet carried out.')).toBeVisible();
});

test('records an execution without ending the measure', async ({ page }) => {
  await openMeasures(page);

  await page.getByRole('button', { name: 'W26-00114' }).click();
  await page.getByLabel('Note').fill('Entry at 06:15, two officers.');
  await page.getByRole('button', { name: 'Record as carried out' }).click();

  await expect(page.getByText(/Carried out/)).toBeVisible();

  // Still valid afterwards: RB allows a husrannsakan to be resumed, so this
  // is a record of what happened and not a state change that closes it.
  await expect(page.getByRole('alert')).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Revoke' })).toBeVisible();
});

test('Escape closes the revocation dialog, not the whole interface', async ({ page }) => {
  await openMeasures(page);

  await page.getByRole('button', { name: 'W26-00114' }).click();
  await page.getByRole('button', { name: 'Revoke' }).click();

  const dialog = page.getByRole('dialog');
  await expect(dialog).toBeVisible();

  await page.keyboard.press('Escape');

  await expect(dialog).toHaveCount(0);
  await expect(page.getByRole('heading', { name: 'W26-00114' })).toBeVisible();
});

test('revoking says so on the record', async ({ page }) => {
  await openMeasures(page);

  await page.getByRole('button', { name: 'W26-00114' }).click();
  await page.getByRole('button', { name: 'Revoke' }).click();
  await page.getByRole('dialog').getByRole('button', { name: 'Revoke' }).click();

  await expect(page.getByRole('alert')).toContainText('Revoked');
  // And the measure is gone from the default list, which is the list an
  // officer checks before acting on one.
  await expect(page.getByRole('button', { name: 'W26-00114' })).toHaveCount(0);
});

test('draws a measure it may not open as a restricted row', async ({ page }) => {
  await openMeasures(page);

  // Two stubs, neither carrying an id (4.5). Two collide on `undefined` and
  // the table refuses to render if the list is keyed by it.
  await expect(page.getByText('Restricted record — Contact Internal Affairs')).toBeVisible();
  await expect(page.getByText('Restricted record — Contact Homicide')).toBeVisible();
});

test('does not ask for a query reason on a workflow tab', async ({ page }) => {
  await page.goto('/');
  await page.locator('nav').first().getByRole('button', { name: 'Records' }).click();

  // The registers do take one (7.2) …
  await expect(page.getByRole('group', { name: 'Query authority' })).toBeVisible();

  await page.getByRole('button', { name: 'Coercive measures', exact: true }).click();

  // … and `tvang.list` does not. A form that asks for a reason and then drops
  // it tells the officer their search was logged with one when it was not.
  await expect(page.getByRole('group', { name: 'Query authority' })).toHaveCount(0);
});

test('renders the measures tab in Swedish', async ({ page }) => {
  await page.goto('/?locale=sv');

  await page.locator('nav').first().getByRole('button', { name: 'Register' }).click();
  await page.getByRole('button', { name: 'Tvångsmedel', exact: true }).click();

  await expect(page.getByRole('button', { name: 'W26-00114' })).toBeVisible();
  await page.getByRole('button', { name: 'W26-00114' }).click();

  await expect(page.getByRole('heading', { name: 'Verkställighet' })).toBeVisible();
  await expect(page.getByText('Ännu inte verkställt.')).toBeVisible();
  await expect(page.getByText('Skyddad post — Kontakta Internutredningen')).toBeVisible();
});
