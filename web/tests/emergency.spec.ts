import { expect, test } from '@playwright/test';
import type { Page } from '@playwright/test';

/**
 * The officer-down banner against the mock bridge (spec 7.16).
 *
 * This file exists because of a button that could only ever be refused. The
 * tone `unit.emergency` sends deliberately reaches past the people who may
 * acknowledge it: after the read check it goes to every SUPERVISE or ASSIGNS
 * holder, and otherwise to whoever is inside 800 m of the position the server
 * read off the caller's own ped -- which is patrol officers, and patrol does
 * not hold `cad.unit.manage`. The banner drew Acknowledge for all of them.
 * Pressing it answered `forbidden` with no field reason, the banner clears only
 * on `acknowledgedAt` or a terminal status so it then stayed up for the rest of
 * the incident, and every press wrote an `audit.denied` row against an officer
 * who had done nothing wrong.
 *
 * The server now answers that question per recipient and sends `mayAcknowledge`
 * with the tone. What is asserted here is that the console draws *that* answer
 * and does not invent one: present when the flag says yes, absent when it says
 * no, and absent when there is no flag at all -- a server that has not learned
 * to send it must not be read as a yes (invariant 4).
 *
 * The push arrives as a `window` message, which is the shape the real transport
 * uses inside CEF; `modules/cad/push.ts` is what makes the mock bridge accept
 * one, and the comment there says why that seam exists at all.
 */

interface BannerOptions {
  mayAcknowledge?: boolean;
}

/**
 * Opens the console with no call selected.
 *
 * Deliberately not `openFirstCall` from `dispatch.spec.ts`: the call card draws
 * an Acknowledge of its own for an unacknowledged emergency, so a page-wide
 * lookup with a card open would pass or fail on the wrong control. With nothing
 * selected the card reads "Select a call", and the only Acknowledge that can be
 * on screen is the banner's.
 */
async function openConsole(page: Page, locale?: string): Promise<void> {
  const swedish = locale === 'sv';

  await page.goto(locale ? `/?locale=${locale}` : '/');
  await page
    .locator('nav')
    .first()
    .getByRole('button', { name: swedish ? 'Ledningscentral' : 'Dispatch' })
    .click();

  // The queue has to have loaded before anything is pushed at it: the console
  // subscribes as it mounts, and a message posted at a page that is still
  // fetching would be a race this test would lose intermittently rather than a
  // behaviour it asserts.
  await expect(
    page.getByRole('button', { name: swedish ? /Skottlossning/ : /Shots fired/ }),
  ).toBeVisible();
}

/**
 * A colleague's panic, pushed the way the server pushes one.
 *
 * `mayAcknowledge` is left off the payload entirely when it is not given, which
 * is the third case worth covering: it is what an older FXServer, or a resource
 * raising its own emergency through the same event, sends.
 */
async function pushEmergency(page: Page, options: BannerOptions = {}): Promise<void> {
  await page.evaluate((flag) => {
    const call = {
      id: 9001,
      callNumber: '260918-0099',
      type: 'officer_emergency',
      priority: 1,
      status: 'dispatched',
      x: 210.4,
      y: -810.2,
      z: 30.7,
      locationText: 'Vespucci Blvd',
      beatId: null,
      callerName: null,
      callerPhone: null,
      source: 'panic',
      sourceResource: null,
      receivedAt: new Date().toISOString().slice(0, 19),
      receivedAtUnix: Math.floor(Date.now() / 1000),
      dispatchedAt: null,
      enRouteAt: null,
      onSceneAt: null,
      clearedAt: null,
      disposition: null,
      acknowledgedBy: null,
      acknowledgedAt: null,
    };

    window.postMessage(
      {
        type: 'fredpd:cad:emergency',
        call,
        callsign: '3A-12',
        ...(flag === null ? {} : { mayAcknowledge: flag }),
      },
      window.location.origin,
    );
  }, options.mayAcknowledge ?? null);
}

test.describe('the officer-down banner', () => {
  test('draws Acknowledge for the recipient the server said may give it', async ({ page }) => {
    await openConsole(page);
    await pushEmergency(page, { mayAcknowledge: true });

    await expect(page.getByText('3A-12 — emergency at Vespucci Blvd')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Respond' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Acknowledge' })).toBeVisible();
  });

  test('draws Respond and no Acknowledge for everybody else', async ({ page }) => {
    await openConsole(page);
    await pushEmergency(page, { mayAcknowledge: false });

    // The tone still reaches them and still says where: an officer 200 m away
    // running to it is the entire point of the range test, and Respond is what
    // they press. What is gone is the button that answered `forbidden` and left
    // an `audit.denied` row behind every time.
    await expect(page.getByText('3A-12 — emergency at Vespucci Blvd')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Respond' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Acknowledge' })).toHaveCount(0);
  });

  test('treats a missing flag as no, not as yes', async ({ page }) => {
    await openConsole(page);
    await pushEmergency(page);

    await expect(page.getByText('3A-12 — emergency at Vespucci Blvd')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Respond' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Acknowledge' })).toHaveCount(0);
  });

  test('the officer who pressed the button is not offered their own sign-off', async ({ page }) => {
    await openConsole(page);

    // Through the button rather than a posted message, because this is the one
    // case the fixtures can raise honestly end to end: `unit.emergency` creates
    // the call, attaches the caller and pushes the tone back at them. The server
    // refuses their acknowledgement on `created_by` before it even looks at the
    // permission, so the one banner they must never be offered a sign-off on is
    // their own.
    // The console's own tab strip, which is the second `nav` on the page --
    // the first is the module rail the shell draws.
    await page.locator('nav').last().getByRole('button', { name: 'Units', exact: true }).click();
    await page.getByRole('button', { name: 'Emergency', exact: true }).click();
    await page.getByRole('button', { name: 'Emergency', exact: true }).click();

    await expect(page.getByText('12-40 — emergency')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Respond' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Acknowledge' })).toHaveCount(0);
  });

  test('renders the banner in Swedish', async ({ page }) => {
    await openConsole(page, 'sv');
    await pushEmergency(page, { mayAcknowledge: true });

    await expect(page.getByText('3A-12 — nödlarm vid Vespucci Blvd')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Rycker ut' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Kvittera' })).toBeVisible();
  });
});
