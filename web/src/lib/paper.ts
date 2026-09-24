/**
 * A printed document as a paper copy carries it (spec 7.28, ADR-020).
 *
 * What arrives here is an inventory item's metadata: written by the server
 * when it printed, but carried by the item, so it is read as untrusted input.
 * Only known shapes survive, text stays text, and nothing is ever rendered as
 * markup (invariant 10).
 */

export interface PaperText {
  text: string;
  bold: boolean;
  italic: boolean;
}

export type PaperBlock =
  | { type: 'paragraph'; content: PaperText[] }
  | { type: 'heading'; level: 2 | 3 | 4; content: PaperText[] }
  | { type: 'list'; ordered: boolean; items: PaperBlock[][] };

export interface PaperDocument {
  title: string;
  number: string;
  agency: string;
  classification: string;
  printedAt: string;
  printedBy: string;
  cut: boolean;
  fields: { label: string; value: string }[];
  body: PaperBlock[];
}

const LIMIT_BLOCKS = 400;

function str(value: unknown, max = 2000): string {
  return typeof value === 'string' ? value.slice(0, max) : '';
}

function inline(nodes: unknown): PaperText[] {
  if (!Array.isArray(nodes)) return [];

  return nodes
    .filter((node): node is { type: string; text?: unknown; marks?: unknown } => typeof node === 'object' && node !== null)
    .filter((node) => node.type === 'text')
    .map((node) => {
      const marks = Array.isArray(node.marks) ? (node.marks as { type?: unknown }[]) : [];
      return {
        text: str(node.text, 20000),
        bold: marks.some((mark) => mark.type === 'bold'),
        italic: marks.some((mark) => mark.type === 'italic'),
      };
    });
}

function blocks(nodes: unknown, depth = 0): PaperBlock[] {
  if (!Array.isArray(nodes) || depth > 4) return [];

  const out: PaperBlock[] = [];

  for (const node of nodes.slice(0, LIMIT_BLOCKS)) {
    if (typeof node !== 'object' || node === null) continue;
    const typed = node as { type?: unknown; content?: unknown; attrs?: { level?: unknown } };

    if (typed.type === 'paragraph') {
      out.push({ type: 'paragraph', content: inline(typed.content) });
    } else if (typed.type === 'heading') {
      const level = Math.min(4, Math.max(2, Number(typed.attrs?.level) || 2)) as 2 | 3 | 4;
      out.push({ type: 'heading', level, content: inline(typed.content) });
    } else if (typed.type === 'bulletList' || typed.type === 'orderedList') {
      const items = Array.isArray(typed.content) ? typed.content : [];
      out.push({
        type: 'list',
        ordered: typed.type === 'orderedList',
        items: items
          .slice(0, LIMIT_BLOCKS)
          .map((item) => blocks((item as { content?: unknown } | null)?.content, depth + 1)),
      });
    }
    // Anything else is dropped, never passed through.
  }

  return out;
}

/** The paper, or null for anything that is not one. */
export function parsePaper(value: unknown): PaperDocument | null {
  if (typeof value !== 'object' || value === null) return null;
  const raw = value as Record<string, unknown>;
  if (typeof raw['title'] !== 'string') return null;

  const fields = Array.isArray(raw['fields'])
    ? (raw['fields'] as unknown[])
        .filter((field): field is Record<string, unknown> => typeof field === 'object' && field !== null)
        .slice(0, 40)
        .map((field) => ({ label: str(field['label'], 200), value: str(field['value']) }))
    : [];

  const body = raw['body'] as { type?: unknown; content?: unknown } | undefined;

  return {
    title: str(raw['title'], 300),
    number: str(raw['number'], 64),
    agency: str(raw['agency'], 200),
    classification: str(raw['classification'], 32),
    printedAt: str(raw['printedAt'], 32),
    printedBy: str(raw['printedBy'], 64),
    cut: raw['cut'] === true,
    fields,
    body: body && body.type === 'doc' ? blocks(body.content) : [],
  };
}
