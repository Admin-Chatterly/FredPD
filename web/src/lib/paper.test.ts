import { describe, expect, it } from 'vitest';

import { parsePaper } from './paper';

describe('parsePaper', () => {
  it('keeps the known shapes of a printed document', () => {
    const paper = parsePaper({
      title: 'Ordningsbot LSPD-T26-000311',
      number: 'LSPD-D26-000004',
      agency: 'Los Santos Police Department',
      classification: 'internal',
      fields: [{ label: 'Amount', value: '800 kr' }],
      body: {
        type: 'doc',
        content: [
          { type: 'heading', attrs: { level: 1 }, content: [{ type: 'text', text: 'Log' }] },
          { type: 'paragraph', content: [{ type: 'text', text: 'Pay by', marks: [{ type: 'bold' }] }] },
          {
            type: 'orderedList',
            content: [{ type: 'listItem', content: [{ type: 'paragraph', content: [{ type: 'text', text: 'one' }] }] }],
          },
        ],
      },
    });

    expect(paper?.number).toBe('LSPD-D26-000004');
    expect(paper?.fields).toEqual([{ label: 'Amount', value: '800 kr' }]);
    // A heading never outranks the document's own title.
    expect(paper?.body[0]).toMatchObject({ type: 'heading', level: 2 });
    expect(paper?.body[1]).toMatchObject({ type: 'paragraph', content: [{ text: 'Pay by', bold: true }] });
    expect(paper?.body[2]).toMatchObject({ type: 'list', ordered: true });
  });

  it('drops what it does not know, and markup stays text', () => {
    const paper = parsePaper({
      title: 'x',
      body: { type: 'doc', content: [{ type: 'html', content: '<img src=x onerror=alert(1)>' }, { type: 'paragraph', content: [{ type: 'text', text: '<b>hi</b>' }] }] },
    });

    expect(paper?.body).toEqual([{ type: 'paragraph', content: [{ text: '<b>hi</b>', bold: false, italic: false }] }]);
  });

  it('is nothing for something that is not a document', () => {
    expect(parsePaper(null)).toBeNull();
    expect(parsePaper({ fields: [] })).toBeNull();
    expect(parsePaper('title')).toBeNull();
  });
});
