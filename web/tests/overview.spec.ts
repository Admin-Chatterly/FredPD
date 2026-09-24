import { expect, test } from '@playwright/test';

/**
 * The overview: where F6 lands. Five short panels, each from a route the
 * officer's own modules already call, each handing over to the module that
 * does the work.
 */

test('lands on the overview, with the shift, the air, the calls, reports and recent queries', async ({ page }) => {
  await page.goto('/?locale=en');

  await expect(page.locator('nav').first().getByRole('button', { name: 'Overview' })).toHaveAttribute(
    'aria-current',
    'page',
  );

  const shift = page.getByRole('region', { name: 'My shift' });
  await expect(shift).toContainText('A. Lindqvist');
  await expect(shift).toContainText('12-40');
  await expect(shift).toContainText('Available');

  await expect(page.getByRole('region', { name: /On the air/ })).toContainText('Silver saloon, no plates');
  const calls = page.getByRole('region', { name: /Open calls/ });
  await expect(calls).toContainText('Shots fired');
  await expect(calls).toContainText('P1');
  await expect(page.getByRole('region', { name: 'My reports' })).toContainText('Drafts 1');
  await expect(page.getByRole('region', { name: 'My recent queries' })).toBeVisible();
});

test('hands a call over to dispatch, and a report over to the register', async ({ page }) => {
  await page.goto('/?locale=en');

  await page.getByRole('region', { name: /Open calls/ }).getByRole('button', { name: 'Open dispatch' }).click();
  const rail = page.locator('nav').first();
  await expect(rail.getByRole('button', { name: 'Dispatch' })).toHaveAttribute('aria-current', 'page');

  await rail.getByRole('button', { name: 'Overview' }).click();
  await page.getByRole('region', { name: 'My reports' }).getByRole('button', { name: 'Open reports' }).click();
  await expect(rail.getByRole('button', { name: 'Records' })).toHaveAttribute('aria-current', 'page');
});

test('runs a recent query again on the query tab', async ({ page }) => {
  await page.goto('/?locale=en');
  await page.locator('nav').first().getByRole('button', { name: 'Records' }).click();
  await page.getByRole('textbox', { name: 'Search' }).fill('petrov');
  await page.getByRole('button', { name: 'Search', exact: true }).click();
  await expect(page.getByText(/Ran as .* against/)).toBeVisible();

  await page.locator('nav').first().getByRole('button', { name: 'Overview' }).click();
  await page.getByRole('region', { name: 'My recent queries' }).getByRole('button', { name: 'Run petrov again' }).click();

  await expect(page.getByRole('textbox', { name: 'Search' })).toHaveValue('petrov');
  await expect(page.getByText(/Ran as .* against/)).toBeVisible();
});

test('leaves out a panel whose route refuses this session, and keeps the rest', async ({ page }) => {
  await page.goto('/?locale=en&failRoute=broadcast.list&failRoute=anmalan.list');

  await expect(page.getByRole('region', { name: 'My shift' })).toBeVisible();
  await expect(page.getByRole('region', { name: /Open calls/ })).toBeVisible();
  // Not an error box and not an empty panel: a register this session may not
  // read is not mentioned at all.
  await expect(page.getByRole('region', { name: /On the air/ })).toHaveCount(0);
  await expect(page.getByRole('region', { name: 'My reports' })).toHaveCount(0);
  await expect(page.getByRole('alert')).toHaveCount(0);
});

test('in Swedish', async ({ page }) => {
  await page.goto('/?locale=sv');

  await expect(page.getByRole('heading', { level: 1, name: 'Översikt' })).toBeVisible();
  await expect(page.getByRole('region', { name: 'Mitt pass' })).toContainText('Tillgänglig');
  await expect(page.getByRole('region', { name: /Öppna händelser/ })).toContainText('Prio 1');
  await expect(page.getByRole('region', { name: 'Mina anmälningar' })).toContainText('Utkast 1');
});
