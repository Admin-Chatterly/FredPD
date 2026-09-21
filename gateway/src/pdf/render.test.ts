import { describe, expect, it } from 'vitest';

import type { GatewayConfig } from '../config.js';
import { renderDocumentToPdf } from './render.js';
import { documentToHtml } from './document.js';
import type { EditorDocument } from './document.js';

/**
 * The PDF renderer against real Chromium (spec 3.3's technology choice), not
 * a mock of it -- a renderer that only "worked" against a fake headless
 * browser would be the one nobody tested.
 */

const config: GatewayConfig = {
  env: 'development',
  host: '127.0.0.1',
  port: 0,
  secret: 'test-secret',
  replayWindowSeconds: 30,
  media: { directory: '/tmp/unused', tokenTtlSeconds: 300, maxBytes: 1024, publicBaseUrl: 'http://x' },
  pdf: { chromiumExecutable: process.env['PLAYWRIGHT_CHROMIUM_EXECUTABLE'] ?? '/opt/pw-browsers/chromium' },
  scheduler: {
    enabled: false,
    intervalSeconds: 300,
    databaseUrl: null,
    retentionDays: { queryLog: 365, alprReads: 90, staleDrafts: 180, surveillanceSessions: 730 },
  },
};

const sampleBody: EditorDocument = {
  type: 'doc',
  content: [
    { type: 'heading', attrs: { level: 2 }, content: [{ type: 'text', text: 'Händelseförlopp' }] },
    {
      type: 'paragraph',
      content: [
        { type: 'text', text: 'Vittnet såg en ' },
        { type: 'text', text: 'silverfärgad', marks: [{ type: 'bold' }] },
        { type: 'text', text: ' bil.' },
      ],
    },
    {
      type: 'bulletList',
      content: [
        { type: 'listItem', content: [{ type: 'paragraph', content: [{ type: 'text', text: 'Första punkten' }] }] },
        { type: 'listItem', content: [{ type: 'paragraph', content: [{ type: 'text', text: 'Andra punkten' }] }] },
      ],
    },
  ],
};

describe('renderDocumentToPdf', () => {
  it('produces a real PDF', async () => {
    const pdf = await renderDocumentToPdf(config, {
      title: 'LSPD-26-000123',
      fields: [
        { label: 'Author', value: 'A. Lindqvist' },
        { label: 'Status', value: 'Approved' },
      ],
      body: sampleBody,
    });

    expect(pdf.subarray(0, 5).toString('latin1')).toBe('%PDF-');
    expect(pdf.length).toBeGreaterThan(1000);
  }, 20000);

  it('renders a classification banner when one is given', async () => {
    const pdf = await renderDocumentToPdf(config, {
      title: 'LSPD-26-000124',
      fields: [],
      body: { type: 'doc', content: [] },
      classification: 'restricted',
    });

    expect(pdf.subarray(0, 5).toString('latin1')).toBe('%PDF-');
  }, 20000);
});

describe('documentToHtml', () => {
  it('escapes text content, never passing it through as markup', () => {
    const html = documentToHtml({
      title: '<script>alert(1)</script>',
      fields: [{ label: 'Note', value: '<img onerror=alert(1)>' }],
      body: {
        type: 'doc',
        content: [{ type: 'paragraph', content: [{ type: 'text', text: '<b>not bold</b>' }] }],
      },
    });

    expect(html).not.toContain('<script>alert(1)</script>');
    expect(html).not.toContain('<img onerror=alert(1)>');
    expect(html).not.toContain('<b>not bold</b>');
    expect(html).toContain('&lt;script&gt;');
  });

  it('drops a node type it does not recognise rather than passing it through', () => {
    const html = documentToHtml({
      title: 'Test',
      fields: [],
      body: {
        type: 'doc',
        // `rawHtml` is not one of this module's node types -- there is no
        // such type, on purpose (invariant 10). A malformed or forward-
        // incompatible document must render as *less*, never as whatever
        // the unknown node happened to carry.
        content: [{ type: 'rawHtml', html: '<script>alert(1)</script>' } as never],
      },
    });

    expect(html).not.toContain('<script>alert(1)</script>');
  });

  it('applies bold and italic marks without opening them up to injection', () => {
    const html = documentToHtml({
      title: 'Test',
      fields: [],
      body: {
        type: 'doc',
        content: [
          {
            type: 'paragraph',
            content: [{ type: 'text', text: 'onclick="alert(1)"', marks: [{ type: 'bold' }] }],
          },
        ],
      },
    });

    expect(html).toContain('<strong>onclick=&quot;alert(1)&quot;</strong>');
  });
});
