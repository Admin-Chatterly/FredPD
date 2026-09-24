import { expect, test } from '@playwright/test';
import type { Page } from '@playwright/test';

/**
 * Photographs through the gateway (spec 7.3, 7.9; ADR-019) against the mock
 * bridge: the record shows what is on file by a signed link, and a new
 * photograph is begun, taken by the client and committed.
 */

async function openJohnDoe(page: Page): Promise<void> {
  await page.goto('/?locale=en');
  await page.locator('nav').first().getByRole('button', { name: 'Records' }).click();
  await page.getByRole('button', { name: 'Field interviews', exact: true }).click();

  const cards = page.getByRole('region', { name: 'Field interview cards' });
  await cards.getByRole('row').filter({ hasText: 'Doe, John' }).getByRole('button').click();
  await cards.getByRole('definition').getByRole('button', { name: /Doe, John/ }).click();
}

test('shows a photograph on file and enlarges it', async ({ page }) => {
  await openJohnDoe(page);

  const enlarge = page.getByRole('button', { name: 'Show the Mugshot at full size' });
  await expect(enlarge.getByRole('img', { name: 'Mugshot' })).toBeVisible();

  await enlarge.click();
  await expect(enlarge).toHaveAttribute('aria-expanded', 'true');
  await expect(page.getByRole('img', { name: 'Mugshot' })).toHaveCount(2);
});

test('takes a photograph of a tattoo for the record', async ({ page }) => {
  await openJohnDoe(page);

  await page.getByRole('combobox', { name: /^Kind of photograph/ }).selectOption('tattoo');
  await page.getByRole('button', { name: 'Take photograph' }).click();

  await expect(page.getByRole('status')).toHaveText('Photograph added to the record.');
  await expect(page.getByRole('button', { name: 'Show the Tattoo at full size' })).toBeVisible();
});

test('takes a mugshot at the booking terminal', async ({ page }) => {
  await page.goto('/?locale=en');
  await page.locator('nav').first().getByRole('button', { name: 'Booking' }).click();
  await page.getByRole('button', { name: 'B26-00042' }).click();

  await page.getByRole('button', { name: 'Take mugshot' }).click();
  await expect(page.getByRole('status')).toHaveText('Mugshot filed with booking B26-00042.');
});

test('files a ten-print from the booking screen', async ({ page }) => {
  await page.goto('/?locale=en');
  await page.locator('nav').first().getByRole('button', { name: 'Booking' }).click();
  await page.getByRole('button', { name: 'B26-00042' }).click();

  await page.getByRole('button', { name: 'Capture ten-print' }).click();
  await expect(page.getByRole('status')).toHaveText('Ten-print filed against B26-00042.');
});

test('offers the photograph in Swedish', async ({ page }) => {
  await page.goto('/?locale=sv');
  await page.locator('nav').first().getByRole('button', { name: 'Register' }).click();
  await page.getByRole('button', { name: 'Kontaktkort', exact: true }).click();

  const cards = page.getByRole('region', { name: 'Kontaktkort' });
  await cards.getByRole('row').filter({ hasText: 'Doe, John' }).getByRole('button').click();
  await cards.getByRole('definition').getByRole('button', { name: /Doe, John/ }).click();

  await expect(page.getByRole('button', { name: 'Ta fotografi' })).toBeVisible();
});
