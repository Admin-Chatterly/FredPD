import { expect, test } from '@playwright/test';
import type { Locator, Page } from '@playwright/test';

/**
 * The dispatch console against the mock bridge (spec 7.16).
 *
 * These exist because of what happened without them. `call.link` shipped with
 * no fixture for `person.search` or `vehicle.search`, so the picker could not
 * be pressed in `pnpm dev:web` and no test could reach it either -- and the
 * seed granted `cad.call.link` to a group holding neither `rms.person.view`
 * nor `rms.vehicle.view`. Every Search a dispatcher pressed answered
 * `forbidden`, for a whole milestone, and the reason nobody noticed is that
 * nothing pressed the button. So the point of the file is less "the picker
 * renders" than "the picker is reachable at all".
 *
 * `shell.spec.ts` covers the rail, the admin screen and intelligence.
 */

/**
 * Opens the console on the P1 at the top of the queue, which has no links yet.
 *
 * The call is chosen by its type rather than by its number: a call number is
 * allocated from `fpd_counters` and carries the date it was raised
 * (`260918-0041`, Appendix D), so a test that matched on one would pass on the
 * day it was written and never again.
 */
async function openFirstCall(page: Page, locale?: string): Promise<void> {
  const swedish = locale === 'sv';

  await page.goto(locale ? `/?locale=${locale}` : '/');
  await page
    .locator('nav')
    .first()
    .getByRole('button', { name: swedish ? 'Ledningscentral' : 'Dispatch' })
    .click();

  // The queue and the card sit side by side, so the card is empty until a call
  // is chosen -- which is the console's own shape and not a loading state.
  await page.getByRole('button', { name: swedish ? /Skottlossning/ : /Shots fired/ }).click();
}

/**
 * The persons-and-vehicles panel: the links, the picker and its results.
 *
 * Scoped to the panel, because a linked record is also named in the narrative
 * below it -- "Ellen Doe linked as Witness." -- so a page-wide lookup for a
 * name matches the log line as well as the row and asserts nothing about where
 * the record actually ended up.
 *
 * `.last()` is what makes it the panel and not the console. `Dispatch.svelte`
 * wraps the whole screen in a `<section>` of its own, so filtering every
 * section by this heading matches that wrapper as well as the panel inside it
 * -- and the wrapper holds the rest of the card, the unit self-assign button
 * included. A negative assertion against the loose locator therefore fails on
 * a button that is correctly somewhere else, which is the worst way for a test
 * to be wrong: it reports a bug in the thing it was written to protect.
 * Document order puts an ancestor first, so the innermost match is last.
 */
function linkPanel(page: Page, heading: string): Locator {
  return page
    .locator('section')
    .filter({ has: page.getByRole('heading', { name: heading }) })
    .last();
}

test.describe('the call card picker', () => {
  test('finds a person and links them to the call', async ({ page }) => {
    await openFirstCall(page);

    const links = linkPanel(page, 'Persons and vehicles');
    await expect(links.getByText('Nothing linked to this call.')).toBeVisible();

    await links.getByLabel('Search term').fill('doe');
    await links.getByRole('button', { name: 'Search', exact: true }).click();

    // Two readable Does. The picker prints the record number beside the name
    // because a department has more than one John Doe.
    await expect(links.getByText('John Doe · P-000431')).toBeVisible();
    await expect(links.getByText('Ellen Doe · P-000512')).toBeVisible();

    const candidate = links.getByRole('listitem').filter({ hasText: 'Ellen Doe · P-000512' });
    await candidate.getByRole('combobox').selectOption('witness');
    await candidate.getByRole('button', { name: 'Link to call' }).click();

    // What the link list carries is what the server recorded: the label
    // `Repo.linkTarget` builds, and the role that was chosen beside the row.
    const linked = links.getByRole('listitem').filter({ hasText: 'Ellen Doe' });
    await expect(linked).toHaveCount(1);
    await expect(linked.getByRole('button', { name: 'Unlink' })).toBeVisible();
    await expect(linked.getByRole('combobox')).toHaveValue('witness');

    // 7.16.1: the generated line is stored as a key and its arguments, so it
    // reads in the language of whoever opens the call and not of whoever linked.
    await expect(page.getByText('Ellen Doe linked as Witness.')).toBeVisible();
  });

  test('says how many matches were withheld rather than shortening the list', async ({ page }) => {
    await openFirstCall(page);

    const links = linkPanel(page, 'Persons and vehicles');

    await links.getByLabel('Search term').fill('doe');
    await links.getByRole('button', { name: 'Search', exact: true }).click();

    // The third Doe is restricted (4.5): the reader is told the search reached
    // something and not what. A stub carries no id, so there is nothing to
    // link -- and a dispatcher who can see that name in front of them needs to
    // know why it is missing from the picker, not a silently shorter list.
    await expect(links.getByText('1 restricted — cannot be linked')).toBeVisible();

    // The search did match, so the empty message must not be drawn beside the
    // rows it returned.
    await expect(links.getByText('No person matches.')).toHaveCount(0);
  });

  test('a term that matches nothing is not the same answer as a withheld one', async ({ page }) => {
    await openFirstCall(page);

    const links = linkPanel(page, 'Persons and vehicles');

    await links.getByLabel('Search term').fill('zzzz');
    await links.getByRole('button', { name: 'Search', exact: true }).click();

    await expect(links.getByText('No person matches.')).toBeVisible();
    await expect(links.getByText(/restricted — cannot be linked/)).toHaveCount(0);
  });

  test('reads the register\'s own refusal out rather than doing nothing', async ({ page }) => {
    await openFirstCall(page);

    const links = linkPanel(page, 'Persons and vehicles');

    // `Repo.parseTerm` refuses a term under two characters before it reaches
    // the database, and the card names the box the server objected to (3.5).
    await links.getByLabel('Search term').fill('d');
    await links.getByRole('button', { name: 'Search', exact: true }).click();

    await expect(page.getByText('The form contains errors.')).toBeVisible();
    await expect(page.getByText('Search term — too short')).toBeVisible();
  });

  test('the link and self-assign buttons no longer share a name', async ({ page }) => {
    await openFirstCall(page);

    // Both read 'Attach to call'. Two differently-behaved buttons under one
    // accessible name is ambiguous to a screen reader and to this test, and a
    // dispatcher who meant one and pressed the other joined a call they were
    // only filing a name against.
    const links = linkPanel(page, 'Persons and vehicles');

    await links.getByLabel('Search term').fill('doe');
    await links.getByRole('button', { name: 'Search', exact: true }).click();

    await expect(links.getByRole('button', { name: 'Link to call' }).first()).toBeVisible();
    await expect(links.getByRole('button', { name: 'Attach to call' })).toHaveCount(0);

    // And the one that does attach a unit is still on the card, under its own
    // name, where 7.16 puts it.
    await expect(page.getByRole('button', { name: 'Attach to call' }).first()).toBeVisible();
  });

  test('searches the vehicle register when the type is switched', async ({ page }) => {
    await openFirstCall(page);

    const links = linkPanel(page, 'Persons and vehicles');

    // Not an exact name: Chromium folds a wrapping label's select value into
    // its text, so this one is "Type Person" until it is switched.
    await links.getByLabel('Type').selectOption('vehicle');
    await links.getByLabel('Search term').fill('45');
    await links.getByRole('button', { name: 'Search', exact: true }).click();

    // A plate and its model, because a department has more than one black
    // saloon -- and `Repo.linkTarget` writes the plate on the link itself.
    await expect(links.getByText('45ABC123 · Sultan')).toBeVisible();
    await expect(links.getByText('45XYZ777 · Sandking')).toBeVisible();
    await expect(links.getByText('1 restricted — cannot be linked')).toBeVisible();

    await links
      .getByRole('listitem')
      .filter({ hasText: '45XYZ777' })
      .getByRole('button', { name: 'Link to call' })
      .click();

    const linked = links.getByRole('listitem').filter({ hasText: '45XYZ777' });
    await expect(linked).toHaveCount(1);
    await expect(linked.getByRole('button', { name: 'Unlink' })).toBeVisible();
  });

  test('renders the picker in Swedish', async ({ page }) => {
    await openFirstCall(page, 'sv');

    const links = linkPanel(page, 'Personer och fordon');

    await links.getByLabel('Sökterm').fill('doe');
    await links.getByRole('button', { name: 'Sök', exact: true }).click();

    await expect(links.getByText('John Doe · P-000431')).toBeVisible();
    await expect(links.getByText('1 skyddade — kan inte kopplas')).toBeVisible();

    await links
      .getByRole('listitem')
      .filter({ hasText: 'Ellen Doe · P-000512' })
      .getByRole('button', { name: 'Koppla till händelsen' })
      .click();

    const linked = links.getByRole('listitem').filter({ hasText: 'Ellen Doe' });
    await expect(linked.getByRole('button', { name: 'Ta bort koppling' })).toBeVisible();
    await expect(page.getByText('Ellen Doe kopplad som Inblandad.')).toBeVisible();
  });
});
