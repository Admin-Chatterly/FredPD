import { expect, test } from '@playwright/test';
import type { Page } from '@playwright/test';

/**
 * Cameras (spec 7.19) against the mock bridge: live view from a terminal, the
 * footage request and its decision, and a still kept under a request.
 */

async function openCameras(page: Page, locale = 'en', placement = '1'): Promise<void> {
  await page.goto(`/?locale=${locale}&placement=${placement}`);
  await page.locator('nav').first().getByRole('button', { name: locale === 'en' ? 'Records' : 'Register' }).click();
  await page.getByRole('button', { name: locale === 'en' ? 'Cameras' : 'Kameror', exact: true }).click();
}

test('lists the cameras there are and starts a live view', async ({ page }) => {
  await openCameras(page);

  const live = page.getByRole('region', { name: 'Live view' });
  await expect(live.getByText('CCTV 12')).toBeVisible();
  await expect(live.getByText('12-41')).toBeVisible();

  await live.getByRole('button', { name: 'Watch CCTV 12' }).click();
  await expect(page.getByRole('alert')).toHaveCount(0);
});

test('says to go to a terminal when the MDT was opened in the field', async ({ page }) => {
  await openCameras(page, 'en', 'none');

  const live = page.getByRole('region', { name: 'Live view' });
  await expect(live.getByText('Watch from a station terminal or the dispatch console.')).toBeVisible();
  await live.getByRole('button', { name: 'Watch CCTV 12' }).click();
  await expect(page.getByRole('alert')).toContainText('watch from a station terminal or the dispatch console');
});

test('requests footage and sees it waiting for approval', async ({ page }) => {
  await openCameras(page);

  const form = page.getByRole('region', { name: 'Request footage' });
  await form.getByRole('combobox', { name: 'Camera', exact: true }).selectOption({ label: 'CCTV 14' });
  await form.getByLabel('Reason').fill('Hit and run at the crossing');
  await form.getByRole('button', { name: 'Request' }).click();

  const status = page.getByRole('status');
  await expect(status).toContainText('sent for approval');
  await expect(status).toBeFocused();
  await expect(page.getByRole('cell', { name: /Hit and run at the crossing/ })).toBeVisible();
});

test('a supervisor approves somebody else’s request, never their own', async ({ page }) => {
  await openCameras(page);

  const requests = page.getByRole('region', { name: 'Footage requests' });
  // An approver opens on what waits for them.
  await expect(requests.getByLabel('Show')).toHaveValue('requested');
  await expect(requests.getByRole('row').filter({ hasText: 'F26-00007' })).toHaveCount(0);

  await requests.getByRole('button', { name: 'Approve F26-00008' }).click();
  const dialog = page.getByRole('dialog', { name: 'Approve' });
  await dialog.getByRole('button', { name: 'Approve' }).click();
  await expect(page.getByRole('status')).toContainText('F26-00008 approved.');

  await requests.getByLabel('Show').selectOption({ label: 'All' });
  await expect(requests.getByRole('row').filter({ hasText: 'F26-00008' })).toContainText('Approved');
  // The viewer's own request offers no decision.
  await expect(requests.getByRole('row').filter({ hasText: 'F26-00007' }).getByRole('button')).toHaveCount(0);
});

test('denies a request, and says so', async ({ page }) => {
  await openCameras(page);

  const requests = page.getByRole('region', { name: 'Footage requests' });
  await requests.getByRole('button', { name: 'Deny F26-00008' }).click();
  const dialog = page.getByRole('dialog', { name: 'Deny' });
  await dialog.getByLabel('Note').fill('No grounds given');
  await dialog.getByRole('button', { name: 'Deny' }).click();
  await expect(page.getByRole('status')).toContainText('F26-00008 denied.');

  await requests.getByLabel('Show').selectOption({ label: 'Denied' });
  await expect(requests.getByRole('row').filter({ hasText: 'F26-00008' })).toContainText('Denied');
});

test('Esc leaves the decision and returns to the button that asked', async ({ page }) => {
  await openCameras(page);

  const approve = page.getByRole('button', { name: 'Approve F26-00008' });
  await approve.focus();
  await page.keyboard.press('Enter');
  await expect(page.getByRole('dialog', { name: 'Approve' })).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(page.getByRole('dialog')).toHaveCount(0);
  await expect(approve).toBeFocused();
});

test('refuses a window longer than a request may ask for', async ({ page }) => {
  await openCameras(page);

  const form = page.getByRole('region', { name: 'Request footage' });
  await form.getByRole('combobox', { name: 'Camera', exact: true }).selectOption({ label: 'CCTV 14' });
  await form.getByLabel('From').fill('2026-09-24T08:00');
  await form.getByLabel('To').fill('2026-09-24T21:00');
  await form.getByLabel('Reason').fill('Hit and run at the crossing');
  await form.getByRole('button', { name: 'Request' }).click();

  const alert = page.getByRole('alert');
  await expect(alert).toContainText('To — the window is longer than a request may ask for');
});

test('keeps a still taken during a view on its request', async ({ page }) => {
  await openCameras(page);

  await page.evaluate(() => {
    window.postMessage(
      {
        type: 'fredpd:cameraStill',
        requestId: 1,
        image: 'data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==',
      },
      '*',
    );
  });

  await expect(page.getByText('Still kept on F26-00007.')).toBeVisible();
  const requests = page.getByRole('region', { name: 'Footage requests' });
  await requests.getByLabel('Show').selectOption({ label: 'Approved' });
  const show = requests.getByRole('button', { name: 'Show the still for F26-00007' });
  await expect(show.getByRole('img', { name: 'Still, F26-00007' })).toBeVisible();

  await show.click();
  await expect(requests.getByRole('button', { name: 'Hide the still for F26-00007' })).toHaveAttribute(
    'aria-expanded',
    'true',
  );
  await expect(requests.getByRole('img', { name: 'Still, F26-00007' })).toHaveCount(2);
});

test('in Swedish', async ({ page }) => {
  await openCameras(page, 'sv');

  await expect(page.getByRole('heading', { name: 'Direktbild' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Begäran om filmmaterial' })).toBeVisible();
  await expect(page.getByRole('cell', { name: 'Väntar på beslut' })).toBeVisible();

  const live = page.getByRole('region', { name: 'Direktbild' });
  await expect(live.getByRole('button', { name: 'Visa Övervakningskamera 12' })).toBeVisible();

  await page.getByRole('button', { name: 'Godkänn F26-00008' }).click();
  const dialog = page.getByRole('dialog', { name: 'Godkänn' });
  await dialog.getByRole('button', { name: 'Godkänn' }).click();
  await expect(page.getByRole('status')).toContainText('F26-00008 är godkänd.');
});

test('in Swedish, away from a terminal', async ({ page }) => {
  await openCameras(page, 'sv', 'none');

  const live = page.getByRole('region', { name: 'Direktbild' });
  await live.getByRole('button', { name: 'Visa Övervakningskamera 12' }).click();
  await expect(page.getByRole('alert')).toContainText('visa från en stationsterminal eller ledningsplatsen');
});
