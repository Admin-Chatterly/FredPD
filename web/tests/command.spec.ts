import { expect, test } from '@playwright/test';

/**
 * The command line in the title bar (Appendix F): what an officer types
 * instead of clicking through. Every command is a navigation or an ordinary
 * route, so these check that the right one happens and that a wrong command
 * says what was wrong.
 */

test('Ctrl+K reaches it from anywhere, and a plate runs the query', async ({ page }) => {
  await page.goto('/?locale=en');
  await page.locator('nav').first().getByRole('button', { name: 'Court' }).click();

  await page.keyboard.press('Control+k');
  const line = page.getByRole('textbox', { name: 'Command', exact: true });
  await expect(line).toBeFocused();

  await line.fill('P ABC123');
  await line.press('Enter');

  // Records, the query tab, holding the plate, and already run.
  await expect(page.getByRole('textbox', { name: 'Search' })).toHaveValue('ABC123');
  await expect(page.getByText(/Ran as/)).toBeVisible();
});

test('sets the unit status from a radio code', async ({ page }) => {
  await page.goto('/?locale=en');

  const line = page.getByRole('textbox', { name: 'Command', exact: true });
  await line.fill('ST BU');
  await line.press('Enter');

  await expect(page.getByText('Status: Busy')).toBeVisible();
  await expect(line).toHaveValue('');
  // Still in the line, ready for the next one.
  await expect(line).toBeFocused();
});

test('says what was wrong with a command it cannot read', async ({ page }) => {
  await page.goto('/?locale=en');

  const line = page.getByRole('textbox', { name: 'Command', exact: true });
  await line.fill('ST XX');
  await line.press('Enter');

  await expect(page.getByText(/Unknown status code/)).toBeVisible();
  // Left as typed, to be corrected rather than retyped.
  await expect(line).toHaveValue('ST XX');
});

test('attaches to the nearest call and clears it', async ({ page }) => {
  await page.goto('/?locale=en');

  const line = page.getByRole('textbox', { name: 'Command', exact: true });
  await line.fill('ATT');
  await line.press('Enter');
  await expect(page.getByText(/Attached to /)).toBeVisible();

  await line.fill('CLR RPT');
  await line.press('Enter');
  // Says which ending it recorded.
  await expect(page.getByText('Call cleared: Report taken.')).toBeVisible();

  // Not on a call any more: said in those words, not as a generic conflict.
  await line.fill('CLR');
  await line.press('Enter');
  await expect(page.getByText('You are not on a call.')).toBeVisible();
});

test('says a command it knows of but cannot do yet is not available', async ({ page }) => {
  await page.goto('/?locale=en');

  const line = page.getByRole('textbox', { name: 'Command', exact: true });
  await line.fill('MSG 1-ADAM-12 on my way');
  await line.press('Enter');

  await expect(page.getByText('That command is not available yet.')).toBeVisible();
});

test('Esc clears a half-typed command instead of closing the MDT', async ({ page }) => {
  await page.goto('/?locale=en');

  const line = page.getByRole('textbox', { name: 'Command', exact: true });
  await line.fill('REG AB');
  await line.press('Escape');

  await expect(line).toHaveValue('');
  await expect(line).toBeVisible();
});

test('takes the Swedish aliases', async ({ page }) => {
  await page.goto('/?locale=sv');

  const line = page.getByRole('textbox', { name: 'Kommando', exact: true });
  await line.fill('REG ABC123');
  await line.press('Enter');

  await expect(page.getByRole('textbox', { name: 'Sök' })).toHaveValue('ABC123');
});
