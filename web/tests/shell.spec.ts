import { expect, test } from '@playwright/test';

/**
 * The shell against the mock bridge (spec 15). These assert the frame holds:
 * the NUI boots without a game, renders what a session is permitted to see, and
 * shows a real message when a route refuses.
 *
 * Screenshot tests for both themes and both languages land with the design
 * tokens in M1, once there is a screen whose appearance is worth pinning.
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
  await expect(rail.getByText('Records')).toBeVisible();
  await expect(rail.getByText('Administration')).toBeVisible();

  // The fixture session holds neither, and the UI must not advertise them.
  await expect(rail.getByText('Intelligence')).toHaveCount(0);
  await expect(rail.getByText('Court')).toHaveCount(0);
});

test('shows a translated message when a route refuses', async ({ page }) => {
  await page.goto('/?fail=forbidden');

  await expect(page.getByText('Your Discord roles do not grant access to this.')).toBeVisible();
});

test('renders in Swedish', async ({ page }) => {
  await page.goto('/?locale=sv');

  await expect(page.getByText('Enhet 12-40')).toBeVisible();
  await expect(page.getByText('I tjänst')).toBeVisible();
  await expect(page.locator('nav').getByText('Register')).toBeVisible();
});
