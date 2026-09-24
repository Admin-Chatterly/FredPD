import { expect, test } from '@playwright/test';
import type { Page } from '@playwright/test';

/**
 * Printing (spec 7.28, ADR-020) against the mock bridge: a paper copy into
 * the inventory, a PDF from the gateway, and reading a paper copy.
 */

async function openCitation(page: Page, locale = 'en'): Promise<void> {
  await page.goto(`/?locale=${locale}`);
  await page.locator('nav').first().getByRole('button', { name: locale === 'en' ? 'Records' : 'Register' }).click();
  await page.getByRole('button', { name: locale === 'en' ? 'Citations' : 'Ordningsböter', exact: true }).click();
  await page.getByRole('button', { name: 'LSPD-T26-000301' }).click();
}

test('prints a paper copy of a citation', async ({ page }) => {
  await openCitation(page);

  await page.getByRole('button', { name: 'Print paper copy' }).click();
  await expect(page.getByRole('status').filter({ hasText: 'Paper copy' })).toContainText('is in your inventory');
});

test('exports a PDF and offers its link', async ({ page }) => {
  await openCitation(page);

  await page.getByRole('button', { name: 'Export PDF' }).click();
  await expect(page.getByRole('status').filter({ hasText: 'PDF' })).toContainText('is ready');
  await expect(page.getByLabel(/Link to the PDF/)).toHaveValue(/^https:\/\/media\.example\/media\//);
});

test('reads a paper copy, as text, and puts it away', async ({ page }) => {
  await page.goto('/?locale=en');
  await expect(page.locator('nav').first()).toBeVisible();

  await page.evaluate(() => {
    window.postMessage(
      {
        type: 'fredpd:paper',
        document: {
          title: 'Summary fine LSPD-T26-000301',
          number: 'LSPD-D26-000004',
          agency: 'Los Santos Police Department',
          classification: 'Internal',
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
  });

  const paper = page.getByRole('article', { name: 'Summary fine LSPD-T26-000301' });
  await expect(paper).toBeVisible();
  await expect(paper.getByText('800 kr')).toBeVisible();
  // Markup in a paper stays text.
  await expect(paper.getByText('<b>Pay by Friday.</b>')).toBeVisible();
  await expect(paper.getByRole('button', { name: 'Put away' })).toBeFocused();

  await paper.getByRole('button', { name: 'Put away' }).click();
  await expect(paper).toHaveCount(0);
});

test('prints in Swedish', async ({ page }) => {
  await openCitation(page, 'sv');

  await expect(page.getByRole('button', { name: 'Skriv ut papperskopia' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Exportera PDF' })).toBeVisible();
});
