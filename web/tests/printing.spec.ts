import { expect, test } from '@playwright/test';
import type { Page } from '@playwright/test';

/**
 * Printing (spec 7.28, ADR-020) against the mock bridge: the preview, a paper
 * copy into the inventory, a PDF from the gateway, a classified record kept
 * off paper, and reading a paper copy.
 */

async function openCitation(page: Page, locale = 'en', number = 'LSPD-T26-000301'): Promise<void> {
  await page.goto(`/?locale=${locale}`);
  await page.locator('nav').first().getByRole('button', { name: locale === 'en' ? 'Records' : 'Register' }).click();
  await page.getByRole('button', { name: locale === 'en' ? 'Citations' : 'Ordningsböter', exact: true }).click();
  await page.getByRole('button', { name: number }).click();
}

async function postPaper(page: Page, classification: string): Promise<void> {
  await page.evaluate((level) => {
    window.postMessage(
      {
        type: 'fredpd:paper',
        document: {
          title: 'Citation LSPD-T26-000301',
          number: 'LSPD-D26-000004',
          agency: 'Los Santos Police Department',
          classification: level,
          printedAt: '2026-09-24 14:02',
          printedBy: '1-ADAM-12',
          fields: [{ label: 'Amount', value: '800 kr' }],
          body: {
            type: 'doc',
            content: [{ type: 'paragraph', content: [{ type: 'text', text: '<b>Pay by Friday.</b>' }] }],
          },
        },
      },
      '*',
    );
  }, classification);
}

test('previews the page before anything is printed', async ({ page }) => {
  await openCitation(page);

  await page.getByRole('button', { name: 'Print…' }).click();
  const preview = page.getByRole('dialog', { name: 'Print preview' });
  await expect(preview).toBeVisible();
  await expect(preview.getByRole('heading', { name: 'Citation LSPD-T26-000301' })).toBeVisible();
  await expect(preview.getByText('Internal', { exact: true })).toBeVisible();

  // Escape closes the preview, not the interface, and focus goes back.
  await page.keyboard.press('Escape');
  await expect(preview).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Print…' })).toBeFocused();
});

test('prints a paper copy of a citation from the preview', async ({ page }) => {
  await openCitation(page);

  await page.getByRole('button', { name: 'Print…' }).click();
  await page.getByRole('dialog').getByRole('button', { name: 'Print paper copy' }).click();

  await expect(page.getByRole('dialog')).toHaveCount(0);
  await expect(page.getByRole('status').filter({ hasText: 'Paper copy' })).toContainText('is in your inventory');
});

test('exports a PDF and offers its link, with when it runs out', async ({ page }) => {
  await openCitation(page);

  await page.getByRole('button', { name: 'Print…' }).click();
  await page.getByRole('dialog').getByRole('button', { name: 'Export PDF' }).click();

  await expect(page.getByRole('status').filter({ hasText: 'PDF' })).toContainText('is ready');
  await expect(page.getByLabel(/Link to the PDF \(valid until \d{4}-\d{2}-\d{2} \d{2}:\d{2}\)/)).toHaveValue(
    /^https:\/\/media\.example\/media\//,
  );
});

test('keeps a classified record off paper and says why', async ({ page }) => {
  await openCitation(page, 'en', 'LSPD-T26-000254');

  await page.getByRole('button', { name: 'Print…' }).click();
  const preview = page.getByRole('dialog', { name: 'Print preview' });

  await expect(preview.getByText('Restricted', { exact: true })).toBeVisible();
  await expect(preview.getByText(/classified above what may be printed on paper/)).toBeVisible();
  await expect(preview.getByRole('button', { name: 'Print paper copy' })).toHaveCount(0);
  await expect(preview.getByRole('button', { name: 'Export PDF' })).toBeVisible();
});

test('says why nothing was printed, in the preview, and names the PDF service', async ({ page }) => {
  await openCitation(page, 'en', 'LSPD-T26-000287');

  await page.getByRole('button', { name: 'Print…' }).click();
  const preview = page.getByRole('dialog', { name: 'Print preview' });
  await preview.getByRole('button', { name: 'Export PDF' }).click();

  const alert = preview.getByRole('alert');
  await expect(alert).toContainText('Nothing was printed.');
  await expect(alert).toContainText('the PDF service did not answer');
  await expect(alert).not.toContainText('photo');
});

test('reads a paper copy, as text, and puts it away', async ({ page }) => {
  await page.goto('/?locale=en');
  await expect(page.locator('nav').first()).toBeVisible();

  await postPaper(page, 'internal');

  const paper = page.getByRole('article', { name: 'Citation LSPD-T26-000301' });
  await expect(paper).toBeVisible();
  await expect(paper.getByText('800 kr')).toBeVisible();
  // The level is named in the reader's language, never as its raw key.
  await expect(paper.getByText('Internal', { exact: true })).toBeVisible();
  // Markup in a paper stays text.
  await expect(paper.getByText('<b>Pay by Friday.</b>')).toBeVisible();
  // Focus starts on the text, so the keys scroll it.
  await expect(paper.getByRole('region', { name: 'Citation LSPD-T26-000301' })).toBeFocused();

  await paper.getByRole('button', { name: 'Put away' }).click();
  await expect(paper).toHaveCount(0);
});

test('puts a paper away with Escape, without showing the MDT underneath', async ({ page }) => {
  await page.goto('/?locale=en');
  await expect(page.locator('nav').first()).toBeVisible();

  await postPaper(page, 'internal');
  const paper = page.getByRole('article', { name: 'Citation LSPD-T26-000301' });
  await expect(paper).toBeVisible();
  await expect(page.locator('.fredpd-stage')).toBeHidden();

  await page.keyboard.press('Escape');
  await expect(paper).toHaveCount(0);
  await expect(page.locator('.fredpd-stage')).toBeHidden();
});

test('does not print a classification it does not know', async ({ page }) => {
  await page.goto('/?locale=en');
  await expect(page.locator('nav').first()).toBeVisible();

  await postPaper(page, 'TOP SECRET');
  const paper = page.getByRole('article', { name: 'Citation LSPD-T26-000301' });
  await expect(paper).toBeVisible();
  await expect(paper.getByText('TOP SECRET')).toHaveCount(0);
});

test('prints and reads in Swedish', async ({ page }) => {
  await openCitation(page, 'sv');

  await page.getByRole('button', { name: 'Skriv ut…' }).click();
  const preview = page.getByRole('dialog', { name: 'Förhandsgranskning' });
  await expect(preview.getByRole('button', { name: 'Skriv ut papperskopia' })).toBeVisible();
  await expect(preview.getByRole('button', { name: 'Exportera PDF' })).toBeVisible();
  await preview.getByRole('button', { name: 'Skriv ut papperskopia' }).click();
  await expect(page.getByRole('status').filter({ hasText: 'Papperskopian' })).toContainText('ligger i din packning');

  await postPaper(page, 'internal');
  const paper = page.getByRole('article', { name: 'Citation LSPD-T26-000301' });
  await expect(paper.getByText('Intern', { exact: true })).toBeVisible();
  await expect(paper.getByRole('button', { name: 'Lägg undan' })).toBeVisible();
});

test('a click on the backdrop and then Escape closes the preview, not the interface', async ({ page }) => {
  await openCitation(page);

  await page.getByRole('button', { name: 'Print…' }).click();
  const preview = page.getByRole('dialog', { name: 'Print preview' });
  await expect(preview).toBeVisible();

  // The backdrop covers the device, not the world: its corner, outside the sheet.
  const device = await page.locator('.fredpd-device').boundingBox();
  if (!device) throw new Error('no device frame');
  await page.mouse.click(device.x + 6, device.y + 6);
  await page.keyboard.press('Escape');

  await expect(preview).toHaveCount(0);
  await expect(page.locator('nav').first()).toBeVisible();
});

test('says why a classified record stays off paper, in Swedish', async ({ page }) => {
  await openCitation(page, 'sv', 'LSPD-T26-000254');

  await page.getByRole('button', { name: 'Skriv ut…' }).click();
  const preview = page.getByRole('dialog', { name: 'Förhandsgranskning' });
  await expect(preview.getByText('Begränsat hemlig', { exact: true })).toBeVisible();
  await expect(preview.getByText(/klassad högre än vad som får skrivas ut på papper/)).toBeVisible();
});
