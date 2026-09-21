import { expect, test } from '@playwright/test';
import type { Page } from '@playwright/test';

/**
 * The officer-down banner and the call card's acknowledgement (spec 7.16).
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
 * The second describe covers the *card*, and it is here rather than in
 * `dispatch.spec.ts` because it is the same defect one component further on.
 * Gating the banner left the identical button on the call card, which
 * `page.dispatch` alone opens and which the banner's own Respond button walks
 * you to -- so the officer who had just been correctly refused the button was
 * offered it again two clicks later, directly above the line telling them the
 * call cannot be cleared until somebody acknowledges it. `call.get` answers
 * `mayAcknowledge` for the card the way `unit.emergency` answers it for the
 * tone, and these assert the card draws that and nothing else.
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

/**
 * Opens the card of the colleague's panic that the fixtures seed (call 4).
 *
 * By type and not by number: a call number carries the date it was allocated
 * (`260918-0044`, Appendix D), so a test that matched on one would pass on the
 * day it was written and never again. `Not acknowledged` in the card header is
 * what proves the card that opened is the emergency and not the P1 above it in
 * the queue.
 */
async function openColleaguePanic(page: Page, locale?: string): Promise<void> {
  const swedish = locale === 'sv';

  await openConsole(page, locale);
  await page
    .getByRole('button', { name: swedish ? /Polis i nöd/ : /Officer in distress/ })
    .click();

  await expect(
    page.getByText(swedish ? 'Inte kvitterat' : 'Not acknowledged'),
  ).toBeVisible();
}

test.describe('the call card acknowledgement', () => {
  test('draws Acknowledge on the card of a colleague\'s unacknowledged panic', async ({ page }) => {
    await openColleaguePanic(page);

    // Nothing was pushed, so no banner is on screen and the only Acknowledge
    // that can match is the card's. That is also why this cannot be folded into
    // the banner tests above: with both drawn, neither assertion says which
    // button it found.
    await expect(page.getByRole('button', { name: 'Acknowledge' })).toHaveCount(1);
  });

  test('signs the emergency off and stops offering to do it again', async ({ page }) => {
    await openColleaguePanic(page);

    await page.getByRole('button', { name: 'Acknowledge' }).click();

    // `call.acknowledge` writes who gave it, and the header reads it back --
    // the column is `acknowledged_by` and a second press is refused on
    // `acknowledged_at IS NULL`, so the button has nothing left to do.
    //
    // `exact` because the narrative underneath says the same thing in a
    // sentence ("Emergency acknowledged by 12-40."), which is the generated
    // line 7.16.1 pairs with this write and not the header being asserted.
    await expect(page.getByText('Acknowledged by 12-40', { exact: true })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Acknowledge' })).toHaveCount(0);
  });

  test('draws no Acknowledge on the card the banner\'s own Respond opens', async ({ page }) => {
    await openConsole(page);

    // The exact walk that made this a defect. The session raises its own panic,
    // the tone comes back with `mayAcknowledge: false` -- the server refuses
    // the officer named in `created_by` before it even looks at the permission
    // -- and Respond then opens the card for that same call. The card used to
    // draw the button the banner had just withheld.
    await page.locator('nav').last().getByRole('button', { name: 'Units', exact: true }).click();
    await page.getByRole('button', { name: 'Emergency', exact: true }).click();
    await page.getByRole('button', { name: 'Emergency', exact: true }).click();

    await expect(page.getByText('12-40 — emergency')).toBeVisible();
    await page.getByRole('button', { name: 'Respond' }).click();

    // The card is open on that call: it is a panic, and nobody has signed it
    // off, so the warning under Clear is drawn -- which is precisely the line
    // that used to sit under a button this officer could never press.
    await expect(
      page.getByText('An emergency call cannot be cleared until a supervisor has acknowledged it.'),
    ).toBeVisible();
    await expect(page.getByRole('button', { name: 'Acknowledge' })).toHaveCount(0);
  });

  test('renders the card acknowledgement in Swedish', async ({ page }) => {
    await openColleaguePanic(page, 'sv');

    await expect(page.getByRole('button', { name: 'Kvittera' })).toHaveCount(1);
  });
});
