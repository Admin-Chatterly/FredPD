import { expect, test } from '@playwright/test';
import type { Page } from '@playwright/test';

/**
 * Booking against the mock bridge (spec 7.9) -- inskrivning i arrest, picking
 * up where `frihet`'s gripande chain leaves off.
 */

async function openBooking(page: Page): Promise<void> {
  await page.goto('/?locale=en');
  await page.locator('nav').first().getByRole('button', { name: 'Booking' }).click();
}

test('lists open bookings', async ({ page }) => {
  await openBooking(page);

  await expect(page.getByRole('button', { name: 'B26-00042' })).toBeVisible();
});

test('opens a booking and shows the property inventory', async ({ page }) => {
  await openBooking(page);

  await page.getByRole('button', { name: 'B26-00042' }).click();

  await expect(page.getByText('Wallet, black leather')).toBeVisible();
  await expect(page.getByText('Mobile phone')).toBeVisible();
  await expect(page.getByText('Returned')).toBeVisible();
});

test('adds a property item', async ({ page }) => {
  await openBooking(page);

  await page.getByRole('button', { name: 'B26-00042' }).click();

  const form = page.locator('form').filter({ hasText: 'Item' });
  await form.getByLabel('Item').fill('Car keys');
  await form.getByRole('button', { name: 'Add item' }).click();

  await expect(page.getByText('Car keys')).toBeVisible();
});

test('releases a booking with a reason', async ({ page }) => {
  await openBooking(page);

  await page.getByRole('button', { name: 'B26-00042' }).click();
  await page.getByRole('button', { name: 'Release' }).click();

  const dialog = page.getByRole('dialog');
  await dialog.getByLabel('Reason for release').selectOption('released_no_charge');
  await dialog.getByRole('button', { name: 'Release' }).click();

  await expect(page.getByText('Released, no charge')).toBeVisible();
});

test('draws a restricted booking as a stub', async ({ page }) => {
  await openBooking(page);

  await expect(page.getByText('Restricted record — Contact Internal Affairs')).toBeVisible();
});

test('renders the module in Swedish', async ({ page }) => {
  await page.goto('/?locale=sv');
  await page.locator('nav').first().getByRole('button', { name: 'Häkte' }).click();

  await expect(page.getByRole('button', { name: 'B26-00042' })).toBeVisible();
});

test('books somebody picked from who is held, not by a typed id', async ({ page }) => {
  await openBooking(page);

  // The chains currently open, by number and person, rather than an internal
  // id copied off the custody screen.
  const custody = page.getByRole('combobox', { name: /Custody/ });
  await expect(custody.locator('option').filter({ hasText: /A26-/ }).first()).toBeAttached();
});
