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

test('lists the officer’s own cards and reads one with its associates', async ({ page }) => {
  await openFieldWork(page);

  const cards = page.getByRole('table').first();
  await expect(cards.getByRole('row').filter({ hasText: 'Doe, John' })).toBeVisible();
  // A colleague's card is not "mine".
  await expect(cards.getByRole('row').filter({ hasText: 'Petrov, Marko' })).toHaveCount(0);

  await cards.getByRole('row').filter({ hasText: 'Doe, John' }).getByRole('button').click();
  await expect(page.getByText('Looking into parked cars on Alta Street.', { exact: false })).toBeVisible();
  await expect(page.getByRole('definition').filter({ hasText: 'Petrov, Marko' })).toBeVisible();
});

test('shows every card when "only mine" is cleared', async ({ page }) => {
  await openFieldWork(page);

  await page.getByLabel('Only mine').uncheck();
  await expect(page.getByRole('table').first().getByRole('row').filter({ hasText: 'Petrov, Marko' })).toBeVisible();
});

test('writes a card about a picked person with an associate', async ({ page }) => {
  await openFieldWork(page);

  await page.getByLabel('Person', { exact: true }).first().fill('petrov');
  await page.getByRole('option', { name: /Petrov, Marko/ }).click();
  await page.getByLabel('With (associates)').fill('doe');
  await page.getByRole('option', { name: /Doe, John/ }).click();
  await expect(page.getByRole('button', { name: /Remove Doe, John/ })).toBeVisible();

  const cards = page.getByRole('region', { name: 'Field interview cards' });
  await cards.getByRole('combobox', { name: /^Reason/ }).selectOption('gang_activity');
  await page.getByLabel('What was said and seen').fill('Handed something to the driver of a black Sultan.');
  await page.getByRole('button', { name: 'Write card' }).click();

  await expect(page.getByRole('status')).toHaveText('Field interview card written.');
  await expect(page.getByRole('heading', { name: 'Gang activity' })).toBeVisible();
  await expect(page.getByText('Handed something to the driver of a black Sultan.')).toBeVisible();
});

test('refuses a card that says nothing', async ({ page }) => {
  await openFieldWork(page);

  await page.getByRole('button', { name: 'Write card' }).click();
  await expect(page.getByRole('alert')).toBeVisible();
});

test('records a stop and lists it with the plate', async ({ page }) => {
  await openFieldWork(page);

  const section = page.getByRole('region', { name: 'Stops' });
  const stops = section.getByRole('table');
  await expect(stops.getByRole('row').filter({ hasText: '45ABC123' })).toBeVisible();

  await section.getByRole('combobox', { name: /^Kind/ }).selectOption('pedestrian');
  await section.getByRole('combobox', { name: /^Search/ }).selectOption('frisk');
  await section.getByRole('combobox', { name: /^Result/ }).selectOption('warning');
  await section.getByRole('button', { name: 'Record stop' }).click();

  await expect(page.getByRole('status')).toHaveText('Stop recorded.');
  await expect(stops.getByRole('row').filter({ hasText: 'Frisk' })).toBeVisible();
});

test('reads in Swedish', async ({ page }) => {
  await openFieldWork(page, 'sv');

  await expect(page.getByRole('heading', { name: 'Kontaktkort' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Kontroller' })).toBeVisible();
  await expect(page.getByRole('cell', { name: 'Trafikkontroll' })).toBeVisible();
});
