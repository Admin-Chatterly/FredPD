/**
 * The editor JSON contract (spec 3.3: "Rich text: Tiptap, stored as JSON",
 * invariant 10: "Rich text is editor JSON. Raw HTML is never rendered.").
 *
 * This is the ProseMirror document shape Tiptap's StarterKit produces,
 * narrowed to the node and mark types this renderer knows how to draw. It is
 * written here, ahead of the NUI's own rich-text editor (`handelseforlopp`
 * today is a plain string field — spec 6.4 and 7.7 call for Tiptap and it is
 * not wired up yet), so that editor has a concrete target to produce rather
 * than a second, independent guess at the shape. When it lands, this module
 * is what it round-trips through; nothing here should need to change unless
 * the editor's own node set grows.
 *
 * **There is no node type here for raw HTML, and there never should be.** A
 * node this renderer does not recognise is dropped, not passed through --
 * the one way this contract could reintroduce invariant 10 from the inside is
 * a catch-all "raw" node, and none exists.
 */

export interface TextMark {
  type: 'bold' | 'italic';
}

export interface TextNode {
  type: 'text';
  text: string;
  marks?: TextMark[];
}

export interface ParagraphNode {
  type: 'paragraph';
  content?: TextNode[];
}

export interface HeadingNode {
  type: 'heading';
  attrs?: { level?: number };
  content?: TextNode[];
}

export interface ListItemNode {
  type: 'listItem';
  content?: BlockNode[];
}

export interface BulletListNode {
  type: 'bulletList';
  content?: ListItemNode[];
}

export interface OrderedListNode {
  type: 'orderedList';
  content?: ListItemNode[];
}

export type BlockNode = ParagraphNode | HeadingNode | BulletListNode | OrderedListNode;

export interface EditorDocument {
  type: 'doc';
  content?: BlockNode[];
}

/** Escapes text for HTML: the only thing standing between this and invariant 10. */
function escapeHtml(text: string): string {
  return text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function renderInline(nodes: TextNode[] | undefined): string {
  if (!nodes) return '';

  return nodes
    .map((node) => {
      if (node.type !== 'text' || typeof node.text !== 'string') return '';

      let out = escapeHtml(node.text);

      for (const mark of node.marks ?? []) {
        if (mark.type === 'bold') out = `<strong>${out}</strong>`;
        else if (mark.type === 'italic') out = `<em>${out}</em>`;
      }

      return out;
    })
    .join('');
}

function renderListItems(items: ListItemNode[] | undefined): string {
  return (items ?? [])
    .map((item) => `<li>${renderBlocks(item.content)}</li>`)
    .join('');
}

function renderBlocks(nodes: BlockNode[] | undefined): string {
  if (!Array.isArray(nodes)) return '';

  return nodes
    .map((node) => {
      switch (node.type) {
        case 'paragraph':
          return `<p>${renderInline(node.content)}</p>`;
        case 'heading': {
          // Clamped to h2-h4: the document's own title is the h1, and a body
          // heading that claimed h1 would outrank it.
          const level = Math.min(4, Math.max(2, node.attrs?.level ?? 2));
          return `<h${level}>${renderInline(node.content)}</h${level}>`;
        }
        case 'bulletList':
          return `<ul>${renderListItems(node.content)}</ul>`;
        case 'orderedList':
          return `<ol>${renderListItems(node.content)}</ol>`;
        default:
          // Unrecognised node types are dropped, never passed through --
          // see the module comment. A future node type is a renderer change,
          // not a silent hole.
          return '';
      }
    })
    .join('');
}

export interface DocumentInput {
  /** The record's own heading — a number and a title, e.g. "LSPD-26-000123". */
  title: string;
  /** Key/value pairs drawn above the body: author, date, classification. */
  fields: Array<{ label: string; value: string }>;
  body: EditorDocument;
  /** Printed once, faint, in the header of every page (spec 6, classification banners). */
  classification?: string | undefined;
}

/**
 * Builds the full, self-contained HTML page `render.ts` hands to Chromium.
 *
 * No external stylesheet, no remote font, no script: the same reasoning the
 * NUI's own CSP applies (invariant 9), because this HTML is generated from a
 * record and printed to a file an officer may forward.
 */
export function documentToHtml(input: DocumentInput): string {
  const fieldRows = input.fields
    .map(
      (field) =>
        `<tr><th>${escapeHtml(field.label)}</th><td>${escapeHtml(field.value)}</td></tr>`,
    )
    .join('');

  const classificationBanner = input.classification
    ? `<div class="classification">${escapeHtml(input.classification.toUpperCase())}</div>`
    : '';

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>${escapeHtml(input.title)}</title>
<style>
  body { font-family: 'DejaVu Sans', Arial, sans-serif; font-size: 11pt; color: #111; margin: 0; padding: 32px 40px; }
  h1 { font-size: 16pt; margin: 0 0 4px; }
  h2 { font-size: 13pt; }
  h3 { font-size: 12pt; }
  h4 { font-size: 11pt; }
  table.fields { border-collapse: collapse; margin: 12px 0 20px; width: 100%; }
  table.fields th { text-align: left; font-weight: 600; padding: 2px 12px 2px 0; white-space: nowrap; vertical-align: top; }
  table.fields td { padding: 2px 0; }
  .classification { text-align: center; font-weight: 700; letter-spacing: 2px; border: 1px solid #111; padding: 2px; margin-bottom: 12px; }
  .body p { margin: 0 0 8px; }
</style>
</head>
<body>
${classificationBanner}
<h1>${escapeHtml(input.title)}</h1>
<table class="fields">${fieldRows}</table>
<div class="body">${renderBlocks(input.body.content)}</div>
</body>
</html>`;
}
