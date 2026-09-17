import { expect, test } from '@playwright/test';

/**
 * The shell and the admin screen against the mock bridge (spec 15). These
 * assert the frame holds: the NUI boots without a game, renders what a session
 * is permitted to see, and shows a real message when a route refuses.
 *
 * Screenshot tests for both themes land with the design tokens in M1, once
 * there is a screen whose appearance is worth pinning.
 */

test('renders the shell from fixture data', async ({ page }) => {
  await page.goto('/');

  await expect(page.getByText('Los Santos Police Department')).toBeVisible();
  await expect(page.getByText('Unit 12-40')).toBeVisible();
  await expect(page.getByText('Signed in as A. Lindqvist')).toBeVisible();
  await expect(page.getByText('On duty')).toBeVisible();
});

test('draws only the modules the session is permitted to open', async ({ page }) => {
  await page.goto('/');

  const rail = page.locator('nav');
  await expect(rail.getByRole('button', { name: 'Records' })).toBeVisible();
  await expect(rail.getByRole('button', { name: 'Administration' })).toBeVisible();

  // The fixture session holds neither, and the UI must not advertise them.
  await expect(rail.getByRole('button', { name: 'Intelligence' })).toHaveCount(0);
  await expect(rail.getByRole('button', { name: 'Court' })).toHaveCount(0);
});

test('shows a translated message when a route refuses', async ({ page }) => {
  await page.goto('/?fail=forbidden');

  await expect(page.getByText('Your Discord roles do not grant access to this.')).toBeVisible();
});

test('renders in Swedish', async ({ page }) => {
  await page.goto('/?locale=sv');

  await expect(page.getByText('Enhet 12-40')).toBeVisible();
  await expect(page.getByText('I tjänst')).toBeVisible();
  await expect(page.locator('nav').getByRole('button', { name: 'Register' })).toBeVisible();
});

test.describe('Discord role mapping', () => {
  test('lists the mappings and how fresh the Discord sync is', async ({ page }) => {
    await page.goto('/');
    await page.locator('nav').getByRole('button', { name: 'Administration' }).click();

    await expect(page.getByRole('heading', { name: 'Discord roles' })).toBeVisible();
    await expect(page.getByText('Discord last synced 12 s ago')).toBeVisible();

    await expect(page.getByRole('cell', { name: 'Officer' })).toBeVisible();
    await expect(page.getByRole('cell', { name: '100000000000000001' })).toBeVisible();
    await expect(page.getByRole('cell', { name: 'Supervisor' })).toBeVisible();
  });

  test('adds a mapping and shows it in the table', async ({ page }) => {
    await page.goto('/');
    await page.locator('nav').getByRole('button', { name: 'Administration' }).click();

    await page.getByLabel('Discord role ID').fill('100000000000000009');
    await page.getByLabel('Name (for display)').fill('Dispatcher');
    await page.getByLabel('Permission group').selectOption('dispatch');
    await page.getByRole('button', { name: 'Add mapping' }).click();

    await expect(page.getByRole('cell', { name: 'Dispatcher' })).toBeVisible();
    await expect(page.getByRole('cell', { name: '100000000000000009' })).toBeVisible();
  });

  test('removes a mapping', async ({ page }) => {
    await page.goto('/');
    await page.locator('nav').getByRole('button', { name: 'Administration' }).click();

    const row = page.getByRole('row').filter({ hasText: '100000000000000002' });
    await row.getByRole('button', { name: 'Remove' }).click();

    await expect(page.getByRole('cell', { name: '100000000000000002' })).toHaveCount(0);
    // The other mapping is untouched.
    await expect(page.getByRole('cell', { name: '100000000000000001' })).toBeVisible();
  });
});
