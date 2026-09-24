import { expect, test } from '@playwright/test';

/**
 * The overview: where F6 lands. Five short panels, each from a route the
 * officer's own modules already call, each row handing over to the record it
 * names.
 */

test('lands on the overview, with the shift, broadcasts, calls, reports and recent queries', async ({ page }) => {
  await page.goto('/?locale=en');

  await expect(page.locator('nav').first().getByRole('button', { name: 'Overview' })).toHaveAttribute(
    'aria-current',
    'page',
  );

  const shift = page.getByRole('region', { name: 'My shift', exact: true });
  await expect(shift).toContainText('A. Lindqvist');
  await expect(shift).toContainText('12-40');
  await expect(shift).toContainText('Available');

  await expect(page.getByRole('region', { name: 'Broadcasts', exact: true })).toContainText('Silver saloon, no plates');
  const calls = page.getByRole('region', { name: 'Open calls', exact: true });
  await expect(calls).toContainText('Shots fired');
  await expect(calls).toContainText('P1');
  await expect(page.getByRole('region', { name: 'My reports', exact: true })).toContainText('Draft');
  await expect(page.getByRole('region', { name: 'My recent queries', exact: true })).toBeVisible();
});

test('a call row opens that call, and focus lands on the module', async ({ page }) => {
  await page.goto('/?locale=en');

  const row = page
    .getByRole('region', { name: 'Open calls', exact: true })
    .getByRole('button', { name: /^Open call / })
    .first();
  await row.click();

  const rail = page.locator('nav').first();
  await expect(rail.getByRole('button', { name: 'Dispatch' })).toHaveAttribute('aria-current', 'page');
  await expect(page.locator('main > h1')).toBeFocused();
});

test('a report row opens that report on the reports tab', async ({ page }) => {
  await page.goto('/?locale=en');

  const reports = page.getByRole('region', { name: 'My reports', exact: true });
  await reports.getByRole('button', { name: /^Open report / }).first().click();

  const rail = page.locator('nav').first();
  await expect(rail.getByRole('button', { name: 'Records' })).toHaveAttribute('aria-current', 'page');
  await expect(page.getByRole('button', { name: 'Reports', exact: true })).toHaveAttribute('aria-current', 'page');
});

test('runs a recent query again, in the register it ran against', async ({ page }) => {
  await page.goto('/?locale=en');
  await page.locator('nav').first().getByRole('button', { name: 'Records' }).click();
  await page.getByRole('textbox', { name: 'Search' }).fill('petrov');
  await page.getByRole('button', { name: 'Search', exact: true }).click();
  await expect(page.getByText(/Ran as .* against/)).toBeVisible();

  await page.locator('nav').first().getByRole('button', { name: 'Overview' }).click();
  await page
    .getByRole('region', { name: 'My recent queries', exact: true })
    .getByRole('button', { name: 'Run petrov again' })
    .click();

  await expect(page.getByRole('textbox', { name: 'Search' })).toHaveValue('petrov');
  await expect(page.getByText(/Ran as .* against/)).toBeVisible();
});

test('leaves out a panel whose route refuses this session, and keeps the rest', async ({ page }) => {
  await page.goto('/?locale=en&failRoute=broadcast.list&failRoute=anmalan.list');

  await expect(page.getByRole('region', { name: 'My shift', exact: true })).toBeVisible();
  await expect(page.getByRole('region', { name: 'Open calls', exact: true })).toBeVisible();
  // Not an error and not an empty panel: a register this session may not
  // read is not mentioned at all.
  await expect(page.getByRole('region', { name: 'Broadcasts', exact: true })).toHaveCount(0);
  await expect(page.getByRole('region', { name: 'My reports', exact: true })).toHaveCount(0);
});

test('says a panel failed to load, rather than showing it empty', async ({ page }) => {
  await page.goto('/?locale=en&failRoute=call.list:internal');

  const calls = page.getByRole('region', { name: 'Open calls', exact: true });
  await expect(calls.getByRole('status')).toContainText('Something went wrong');
  await expect(calls.getByRole('button', { name: 'Try again' })).toBeVisible();
  // Nor does the screen claim to be up to date.
  await expect(page.getByText(/^Updated /)).toHaveCount(0);
});

test('in Swedish', async ({ page }) => {
  await page.goto('/?locale=sv');

  await expect(page.getByRole('heading', { level: 1, name: 'Översikt' })).toBeVisible();
  await expect(page.getByRole('region', { name: 'Mitt pass', exact: true })).toContainText('Tillgänglig');
  await expect(page.getByRole('region', { name: 'Utskick', exact: true })).toBeVisible();
  const calls = page.getByRole('region', { name: 'Öppna händelser', exact: true });
  await expect(calls).toContainText('Prio 1');
  await expect(calls.getByRole('button', { name: 'Alla händelser och utskick, i ledningscentralen' })).toBeVisible();
  await expect(page.getByRole('region', { name: 'Mina anmälningar', exact: true })).toContainText('Utkast');
});
