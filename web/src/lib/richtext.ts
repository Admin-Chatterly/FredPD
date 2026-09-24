/**
 * The narrative fields (händelseförlopp) are stored as editor JSON -- a
 * Tiptap/ProseMirror document -- never as HTML (invariant 10). Until a full
 * editor lands, the MDT writes and reads them as plain paragraphs through
 * these two functions: text in, a document of paragraphs out, and back.
 *
 * Reading never produces markup: a document becomes plain text, one blank
 * line between paragraphs, and anything that is not a document (an older
 * plain-text value) is shown as the text it is.
 */

interface DocNode {
  type?: unknown;
  text?: unknown;
  content?: unknown;
}

/** Plain text to a document of paragraphs, as a JSON string. */
export function textToDoc(text: string): string {
  const paragraphs = text
    .replace(/\r\n/g, '\n')
    .split(/\n{2,}/)
    .map((block) => block.trim())
    .filter((block) => block !== '');

  return JSON.stringify({
    type: 'doc',
    content: paragraphs.map((block) => ({
      type: 'paragraph',
      content: [{ type: 'text', text: block }],
    })),
  });
}

function textOf(node: DocNode): string {
  if (typeof node.text === 'string') return node.text;
  if (node.type === 'hardBreak') return '\n';
  if (!Array.isArray(node.content)) return '';

  return (node.content as DocNode[]).map(textOf).join('');
}

/** A stored document (or older plain text) as plain text for a textarea or a <p>. */
export function docToText(value: string | null | undefined): string {
  if (!value) return '';

  let parsed: unknown;
  try {
    parsed = JSON.parse(value);
  } catch {
    return value;
  }

  const doc = parsed as DocNode;
  if (typeof parsed !== 'object' || parsed === null || doc.type !== 'doc' || !Array.isArray(doc.content)) {
    return value;
  }

  return (doc.content as DocNode[]).map(textOf).filter((block) => block !== '').join('\n\n');
}
