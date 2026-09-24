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
  await form.getByLabel('Camera', { exact: true }).selectOption({ label: 'CCTV 14' });
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
  const row = requests.getByRole('row').filter({ hasText: 'F26-00008' });
  await row.getByRole('button', { name: 'Approve' }).click();

  const dialog = page.getByRole('dialog', { name: 'Approve' });
  await dialog.getByRole('button', { name: 'Approve' }).click();
  await expect(page.getByRole('status')).toContainText('F26-00008 is decided.');
  await expect(requests.getByRole('row').filter({ hasText: 'F26-00008' })).toContainText('Approved');

  // The viewer's own request offers no decision.
  await expect(requests.getByRole('row').filter({ hasText: 'F26-00007' }).getByRole('button')).toHaveCount(0);
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
  const row = page.getByRole('region', { name: 'Footage requests' }).getByRole('row').filter({ hasText: 'F26-00007' });
  await expect(row.getByRole('img', { name: 'Open the still' })).toBeVisible();
});

test('in Swedish', async ({ page }) => {
  await openCameras(page, 'sv');

  await expect(page.getByRole('heading', { name: 'Direktbild' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Begäran om filmmaterial' })).toBeVisible();
  await expect(page.getByRole('cell', { name: 'Väntar på beslut' })).toBeVisible();
});
