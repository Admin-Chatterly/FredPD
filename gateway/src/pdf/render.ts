import { chromium } from 'playwright-core';

import type { GatewayConfig } from '../config.js';
import { documentToHtml, type DocumentInput } from './document.js';

/**
 * Renders a record to PDF through headless Chromium (spec 3.3's technology
 * choice), never through a shell-out to a native PDF library that would need
 * its own reimplementation of text layout, page breaks and fonts.
 *
 * The browser is launched per render and closed afterwards rather than kept
 * warm, because the gateway's PDF traffic is bursty -- an approval, a
 * disclosure, a verdict -- and not a steady stream that would justify a pool.
 * A department generating enough documents for that to matter is a tuning
 * problem for later, not a correctness one now.
 */
export async function renderDocumentToPdf(
  config: GatewayConfig,
  input: DocumentInput,
): Promise<Buffer> {
  const html = documentToHtml(input);

  const browser = await chromium.launch({
    executablePath: config.pdf.chromiumExecutable,
    headless: true,
  });

  try {
    const page = await browser.newPage();

    // No `page.goto` to a URL: the content is set directly, so nothing here
    // ever issues a network request the CSP-style reasoning in `document.ts`
    // would have to account for.
    await page.setContent(html, { waitUntil: 'load' });

    const pdf = await page.pdf({
      format: 'A4',
      printBackground: true,
      margin: { top: '16mm', bottom: '16mm', left: '18mm', right: '18mm' },
    });

    return pdf;
  } finally {
    await browser.close();
  }
}
