import { expect, test } from '@playwright/test';
import type { Page } from '@playwright/test';

/**
 * The internal police channel's comms log against the mock bridge (spec
 * 7.26).
 *
 * Sending stays where it already is -- the `/pd` command in the game's own
 * chat box -- so this screen only ever reads `chat.history`; there is no
 * compose form to test here.
 */

async function openComms(page: Page): Promise<void> {
  await page.goto('/?locale=en');
  await page.locator('nav').first().getByRole('button', { name: 'Communications' }).click();
}

test('lists the channel transcript, oldest first', async ({ page }) => {
  await openComms(page);

  const lines = page.getByRole('listitem');
  await expect(lines).toHaveCount(3);
  await expect(lines.first()).toContainText('Requesting backup');
  await expect(lines.last()).toContainText('Logging it');
});

test('shows the callsign and name the server resolved, not a bare id', async ({ page }) => {
  await openComms(page);

  await expect(page.getByRole('listitem').first()).toContainText('12-40 A. Lindqvist');
});

test('refresh re-reads the log', async ({ page }) => {
  await openComms(page);

  await page.getByRole('button', { name: 'Refresh' }).click();

  await expect(page.getByRole('listitem')).toHaveCount(3);
});

test('renders the module in Swedish', async ({ page }) => {
  await page.goto('/?locale=sv');

  await page.locator('nav').first().getByRole('button', { name: 'Kommunikation' }).click();

  await expect(page.getByRole('button', { name: 'Uppdatera' })).toBeVisible();
  await expect(page.getByRole('listitem').first()).toContainText('Requesting backup');
});
