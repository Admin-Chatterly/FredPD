import { expect, test } from '@playwright/test';
import type { Page } from '@playwright/test';

/**
 * Surveillance against the mock bridge (spec 9).
 *
 * Three of these are the reason the module has two capacities and not one:
 *
 *   * **A prosecutor cannot grant their own application.** The fixture
 *     session holds `surv.request`, not `surv.decide` — mirroring
 *     `FIXTURE_TVANG_CAPACITY`'s reasoning for `kroppsbesiktning` — so
 *     pressing "Grant" refuses `wrong_capacity`, and the refusal has to read
 *     as a legal boundary rather than a Discord role problem.
 *   * **A measure that stops authorising anything says why, in words.** The
 *     same three-way split `tvang.spec.ts` pins: refused, revoked, and
 *     (elsewhere) expired are different facts an observer has to be told
 *     apart.
 *   * **A restricted request draws as a stub**, with no id to key a list on.
 */

async function openSurveillance(page: Page): Promise<void> {
  await page.goto('/?locale=en');
  await page.locator('nav').first().getByRole('button', { name: 'Surveillance' }).click();
}

test('lists requests at every stage', async ({ page }) => {
  await openSurveillance(page);

  await expect(page.getByRole('button', { name: 'H26-00003' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'H26-00002' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'H26-00001' })).toBeVisible();
});

test('says a granted measure was refused, in words', async ({ page }) => {
  await openSurveillance(page);

  await page.getByRole('button', { name: 'H26-00001' }).click();

  await expect(page.getByRole('alert')).toContainText('Refused');
});

test('says a granted measure was revoked, in words', async ({ page }) => {
  await openSurveillance(page);

  await page.getByRole('button', { name: 'H25-00099' }).click();

  await expect(page.getByRole('alert')).toContainText('Revoked');
  await expect(page.getByText('Purpose achieved')).toBeVisible();
});

test('refuses a grant as not this officer’s decision', async ({ page }) => {
  await openSurveillance(page);

  await page.getByRole('button', { name: 'H26-00003' }).click();
  await page.getByRole('button', { name: 'Grant' }).click();

  const dialog = page.getByRole('dialog');
  await dialog.getByRole('button', { name: 'Grant' }).click();

  // Scoped to the dialog: the detail panel behind it also carries an alert,
  // for the pending request not authorising anything yet.
  const panel = dialog.getByRole('alert');

  // Not "not this officer" merely by rank — RB gives this decision to the
  // domare alone, and the åklagare who filed the application is exactly the
  // person it must never be.
  await expect(panel).toContainText('That decision is not yours to take.');
  await expect(panel).not.toContainText('wrong_capacity');
});

test('refuses a request', async ({ page }) => {
  await openSurveillance(page);

  await page.getByRole('button', { name: 'H26-00003' }).click();
  await page.getByRole('button', { name: 'Refuse' }).click();

  const dialog = page.getByRole('dialog');
  await dialog.getByLabel('Choose a ground').selectOption('annan');
  await dialog.getByRole('button', { name: 'Refuse' }).click();

  // This workstation cannot decide either, so the same boundary applies —
  // proving refusal is gated the same way grant is, not merely disabled on
  // screen.
  await expect(dialog.getByRole('alert')).toContainText('That decision is not yours to take.');
});

test('files a request against an investigation', async ({ page }) => {
  await openSurveillance(page);

  await page.getByRole('button', { name: 'Request', exact: true }).click();

  const form = page.locator('form').filter({ hasText: 'Investigation' });

  await form.getByLabel('Method').selectOption('sparsandare');
  await form.getByLabel('Directed at').selectOption('vehicle');
  // Not `getByLabel`: one ground option's own text contains the word
  // "investigation" ("Of particular importance to the investigation"), which
  // a `<select>`'s accessible name picks up from its options in Chromium, so
  // a substring match on the label text alone is not unique.
  await form.getByRole('textbox', { name: 'Investigation' }).fill('31');
  await form.getByLabel('Record id').fill('7');
  await form.getByLabel('Choose a ground').selectOption('grov_brottslighet');
  await form.getByRole('button', { name: 'Request', exact: true }).click();

  await expect(page.getByRole('heading', { name: /^H26-/ })).toBeVisible();
  await expect(page.getByText(/filed\./)).toBeVisible();
});

test('asks for a label rather than a record id for a phone number', async ({ page }) => {
  await openSurveillance(page);

  await page.getByRole('button', { name: 'Request', exact: true }).click();

  const form = page.locator('form').filter({ hasText: 'Investigation' });

  await form.getByLabel('Directed at').selectOption('phone');

  // A telephone number is not a foreign key into anything this suite holds
  // (0015), so the id field is replaced rather than merely hidden alongside it.
  await expect(form.getByLabel('Record id')).toHaveCount(0);
  await expect(form.getByLabel('Named as')).toBeVisible();
});

test('observes a live measure and logs a capture', async ({ page }) => {
  await openSurveillance(page);

  await page.getByRole('button', { name: 'H26-00002' }).click();

  await page.getByRole('button', { name: 'Start observing' }).click();
  await expect(page.getByRole('button', { name: 'End observing' })).toBeVisible();

  await page.getByLabel('Kind').selectOption('message');
  await page.getByLabel('Summary').fill('Text confirming a meeting time.');
  await page.getByRole('button', { name: 'Log a capture' }).click();

  await expect(page.getByText('Text confirming a meeting time.')).toBeVisible();

  await page.getByRole('button', { name: 'End observing' }).click();
  await expect(page.getByRole('button', { name: 'Start observing' })).toBeVisible();
});

test('revokes a granted measure early, and says why', async ({ page }) => {
  await openSurveillance(page);

  await page.getByRole('button', { name: 'H26-00002' }).click();
  await page.getByRole('button', { name: 'Revoke' }).click();

  const dialog = page.getByRole('dialog');
  await dialog.getByLabel('Choose a ground').selectOption('skal_upphorda');
  await dialog.getByRole('button', { name: 'Revoke' }).click();

  await expect(page.getByRole('status')).toContainText('revoked');
  await expect(page.getByRole('alert')).toContainText('Revoked');
});

test('Escape closes the dialog, not the whole interface', async ({ page }) => {
  await openSurveillance(page);

  await page.getByRole('button', { name: 'H26-00002' }).click();
  await page.getByRole('button', { name: 'Revoke' }).click();

  const dialog = page.getByRole('dialog');
  await expect(dialog).toBeVisible();

  await page.keyboard.press('Escape');

  await expect(dialog).toHaveCount(0);
  await expect(page.getByRole('heading', { name: 'H26-00002' })).toBeVisible();
});

test('draws a request it may not open as a restricted row', async ({ page }) => {
  await openSurveillance(page);

  await expect(page.getByText('Restricted record — Contact Internal Affairs')).toBeVisible();
  await expect(page.getByText('Restricted record — Contact Homicide')).toBeVisible();
});

test('renders the module in Swedish', async ({ page }) => {
  await page.goto('/?locale=sv');

  await page.locator('nav').first().getByRole('button', { name: 'Hemlig avlyssning' }).click();

  await expect(page.getByRole('button', { name: 'H26-00002' })).toBeVisible();
  await page.getByRole('button', { name: 'H26-00002' }).click();

  await expect(page.getByText('Hemlig rumsavlyssning')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Häv beslutet' })).toBeVisible();
});
