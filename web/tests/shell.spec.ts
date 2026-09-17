import { expect, test } from '@playwright/test';
import type { Page } from '@playwright/test';

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

  const rail = page.locator('nav').first();
  await expect(rail.getByRole('button', { name: 'Records' })).toBeVisible();
  await expect(rail.getByRole('button', { name: 'Intelligence' })).toBeVisible();
  await expect(rail.getByRole('button', { name: 'Administration' })).toBeVisible();

  // The fixture session holds neither, and the UI must not advertise them.
  await expect(rail.getByRole('button', { name: 'Court' })).toHaveCount(0);
  await expect(rail.getByRole('button', { name: 'Dispatch' })).toHaveCount(0);
});

test('shows a translated message when a route refuses', async ({ page }) => {
  await page.goto('/?fail=forbidden');

  await expect(page.getByText('Your Discord roles do not grant access to this.')).toBeVisible();
});

test('renders in Swedish', async ({ page }) => {
  await page.goto('/?locale=sv');

  await expect(page.getByText('Enhet 12-40')).toBeVisible();
  await expect(page.getByText('I tjänst')).toBeVisible();
  await expect(page.locator('nav').first().getByRole('button', { name: 'Register' })).toBeVisible();
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

test.describe('Intelligence', () => {
  async function openIntel(page: Page): Promise<void> {
    await page.goto('/');
    await page.locator('nav').first().getByRole('button', { name: 'Intelligence' }).click();
  }

  test('shows the log, newest first', async ({ page }) => {
    await openIntel(page);

    await expect(page.getByText('Black van, no plates', { exact: false })).toBeVisible();
    await expect(page.getByText('Anonymous call', { exact: false })).toBeVisible();
  });

  test('withholds a protected source but keeps the intelligence readable', async ({ page }) => {
    await openIntel(page);

    // The note from an informant shows that a source exists and is withheld,
    // rather than showing the source or hiding the note (spec 10.6).
    await expect(page.getByText('Protected source')).toBeVisible();
    await expect(page.getByText('moving product through the laundrette', { exact: false }))
      .toBeVisible();

    // Scoped to the log: 'Informant' is also an option in the composer's source
    // dropdown, which says nothing about what this reader may see.
    await expect(page.locator('ol').getByText('Informant')).toHaveCount(0);
  });

  test('filters the log by tag', async ({ page }) => {
    await openIntel(page);

    await page.getByRole('button', { name: /^weapons/ }).first().click();

    await expect(page.getByText('Anonymous call', { exact: false })).toBeVisible();
    await expect(page.getByText('Black van, no plates', { exact: false })).toHaveCount(0);
  });

  test('logs a new entry and shows it', async ({ page }) => {
    await openIntel(page);

    await page.getByLabel('What was observed').fill('Red saloon circling the station.');
    await page.getByLabel('Tags').fill('Surveillance, STATION');
    await page.getByRole('button', { name: 'Log it' }).click();

    await expect(page.getByText('Red saloon circling the station.')).toBeVisible();
  });

  test('lists a person with no name as unknown rather than blank', async ({ page }) => {
    await openIntel(page);
    await page.getByRole('button', { name: 'People' }).click();

    await expect(page.getByText('Marko Petrov')).toBeVisible();
    // A description-only record is a real entry in the register, not a broken row.
    await expect(page.getByText('Unknown person')).toBeVisible();
    await expect(page.getByText('Short, heavy build', { exact: false })).toBeVisible();
  });

  test('lists organizations and cases', async ({ page }) => {
    await openIntel(page);

    await page.getByRole('button', { name: 'Organizations' }).click();
    await expect(page.getByText('Alta Street Crew')).toBeVisible();
    await expect(page.getByText('4 members')).toBeVisible();

    await page.getByRole('button', { name: 'Cases' }).click();
    await expect(page.getByText('Operation Kvarnen')).toBeVisible();
    await expect(page.getByText('2 people, 1 organizations')).toBeVisible();
  });

  test('renders the module in Swedish', async ({ page }) => {
    await page.goto('/?locale=sv');
    await page.locator('nav').first().getByRole('button', { name: 'Underrättelser' }).click();

    await expect(page.getByRole('button', { name: 'Underrättelselogg' })).toBeVisible();
    await expect(page.getByText('Skyddad källa')).toBeVisible();
  });
});
