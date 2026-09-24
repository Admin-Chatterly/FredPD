import { describe, expect, it } from 'vitest';
import { docToText, textToDoc } from './richtext';

describe('richtext', () => {
  it('round-trips paragraphs', () => {
    const text = 'Called to Grove St.\n\nSuspect fled on foot.';
    expect(docToText(textToDoc(text))).toBe(text);
  });

  it('stores editor JSON, not markup', () => {
    const doc = JSON.parse(textToDoc('<b>not bold</b>')) as { content: { content: { text: string }[] }[] };
    expect(doc.content[0]?.content[0]?.text).toBe('<b>not bold</b>');
  });

  it('shows an older plain-text value as it is', () => {
    expect(docToText('Just words')).toBe('Just words');
    expect(docToText(null)).toBe('');
  });
});
