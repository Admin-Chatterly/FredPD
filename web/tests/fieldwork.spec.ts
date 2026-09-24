import { expect, test } from '@playwright/test';
import type { Page } from '@playwright/test';

/**
 * Field interview cards and stop data (spec 7.14) against the mock bridge.
 */

async function openFieldWork(page: Page, locale = 'en'): Promise<void> {
  await page.goto(`/?locale=${locale}`);
  await page.locator('nav').first().getByRole('button', { name: locale === 'en' ? 'Records' : 'Register' }).click();
  await page
    .getByRole('button', { name: locale === 'en' ? 'Field interviews' : 'Kontaktkort', exact: true })
    .click();
}

test('lists the cards and reads one with its associates', async ({ page }) => {
  await openFieldWork(page);

  const cards = page.getByRole('region', { name: 'Field interview cards' });
  const row = cards.getByRole('row').filter({ hasText: 'Doe, John' });
  await expect(row).toBeVisible();

  await row.getByRole('button').click();
  await expect(cards.getByText('Looking into parked cars on Alta Street.', { exact: false })).toBeVisible();
  // Names on a card open the person's own record.
  await expect(cards.getByRole('definition').getByRole('button', { name: /Petrov, Marko/ })).toBeVisible();
});

test('finds the cards about one person, as subject or associate', async ({ page }) => {
  await openFieldWork(page);

  const cards = page.getByRole('region', { name: 'Field interview cards' });
  await page.getByLabel('Cards about a person').fill('petrov');
  await page.getByRole('option', { name: /Petrov, Marko/ }).click();
  await cards.getByRole('button', { name: 'Show cards' }).click();

  // Card 1 names him as an associate, card 2 as its subject.
  await expect(cards.locator('tbody tr')).toHaveCount(2);

  await cards.getByLabel('Only cards I wrote').check();
  await cards.getByRole('button', { name: 'Show cards' }).click();
  await expect(cards.locator('tbody tr')).toHaveCount(1);
});

test('writes a card about a picked person with an associate', async ({ page }) => {
  await openFieldWork(page);

  const cards = page.getByRole('region', { name: 'Field interview cards' });
  await cards.getByRole('button', { name: 'Write a card' }).click();
  // The position is taken only when asked for.
  await expect(cards.getByLabel('Record my current position')).not.toBeChecked();

  await page.getByLabel('Person', { exact: true }).fill('petrov');
  await page.getByRole('option', { name: /Petrov, Marko/ }).click();
  await page.getByLabel('Associates').fill('doe');
  await page.getByRole('option', { name: /Doe, John/ }).click();
  await expect(cards.getByText('1 of 10')).toBeVisible();

  await cards.getByRole('combobox', { name: /^Reason/ }).selectOption('gang_activity');
  await cards.getByLabel('What was said and seen').fill('Handed something to the driver of a black Sultan.');
  await cards.getByRole('button', { name: 'Save card' }).click();

  await expect(cards.getByRole('status')).toHaveText('Field interview card written.');
  await expect(cards.getByRole('heading', { name: 'Gang activity' })).toBeVisible();
  await expect(cards.getByText('Handed something to the driver of a black Sultan.')).toBeVisible();
});

test('removing an associate returns focus to the picker', async ({ page }) => {
  await openFieldWork(page);

  const cards = page.getByRole('region', { name: 'Field interview cards' });
  await cards.getByRole('button', { name: 'Write a card' }).click();
  await page.getByLabel('Associates').fill('doe');
  await page.getByRole('option', { name: /Doe, John/ }).click();
  await cards.getByRole('button', { name: /Remove Doe, John/ }).click();

  await expect(page.getByLabel('Associates')).toBeFocused();
});

test('says what a card needs when it says nothing', async ({ page }) => {
  await openFieldWork(page);

  const cards = page.getByRole('region', { name: 'Field interview cards' });
  await cards.getByRole('button', { name: 'Write a card' }).click();
  await cards.getByRole('button', { name: 'Save card' }).click();

  await expect(cards.getByRole('alert')).toContainText('a card needs a person, a vehicle or a note');
});

test('records a stop from the keyboard and lists it with the plate', async ({ page }) => {
  await openFieldWork(page);
  await page.getByRole('button', { name: 'Stops', exact: true }).click();

  const stops = page.getByRole('region', { name: 'Stops' });
  await expect(stops.getByRole('row').filter({ hasText: '45ABC123' })).toBeVisible();

  await stops.getByRole('button', { name: 'Record a stop' }).click();
  await stops.getByRole('combobox', { name: /^Kind/ }).selectOption('pedestrian');
  await stops.getByRole('combobox', { name: /^Search/ }).selectOption('frisk');
  await stops.getByRole('combobox', { name: /^Result/ }).selectOption('warning');
  await stops.getByRole('combobox', { name: /^Result/ }).press('Control+Enter');

  await expect(stops.getByRole('status')).toHaveText('Stop recorded.');
  await expect(stops.getByRole('row').filter({ hasText: 'Frisk' })).toBeVisible();
});

test('reads in Swedish', async ({ page }) => {
  await openFieldWork(page, 'sv');

  await expect(page.getByRole('heading', { name: 'Kontaktkort' })).toBeVisible();
  await page.getByRole('button', { name: 'Kontroller', exact: true }).click();
  await expect(page.getByRole('cell', { name: 'Fordonskontroll' })).toBeVisible();
});
