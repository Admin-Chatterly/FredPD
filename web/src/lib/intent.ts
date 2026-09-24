/**
 * Where the MDT should land when a field action opens it (client/field.lua's
 * "Open in MDT"): a module, a tab inside it, and a query to run there.
 *
 * Navigation only. Every screen still asks the server for what it draws, so
 * an intent can at most open a screen the session could have clicked to
 * (invariant 4).
 *
 * Held until a screen takes it, because the screen it names is often not
 * mounted yet when the message arrives: App switches module, Records mounts,
 * Records switches tab, Query mounts, Query runs the search.
 */

export interface Intent {
  module: string;
  tab?: string;
  term?: string;
  type?: string;
  /**
   * A record handed over from another screen ("Issue a fine" on a query
   * row): the form it lands on opens filled in with it. Ids the officer was
   * already shown, re-checked by the route that uses them.
   */
  personId?: number;
  vehicleId?: number;
  frihetId?: number;
  /** How to name it on the form, so a filled-in field says who it holds. */
  subjectLabel?: string;
}

type Listener = (intent: Intent) => void;

let pending: Intent | null = null;
const listeners = new Set<Listener>();

/** Reads an intent off a `fredpd:open` message, or null for none. */
export function parseIntent(value: unknown): Intent | null {
  if (typeof value !== 'object' || value === null) return null;

  const raw = value as Record<string, unknown>;
  if (typeof raw['module'] !== 'string') return null;

  const text = (key: string): string | undefined =>
    typeof raw[key] === 'string' ? (raw[key] as string) : undefined;

  const intent: Intent = { module: raw['module'] };
  const tab = text('tab');
  const term = text('term');
  const type = text('type');
  if (tab !== undefined) intent.tab = tab;
  if (term !== undefined) intent.term = term;
  if (type !== undefined) intent.type = type;

  for (const key of ['personId', 'vehicleId', 'frihetId'] as const) {
    const value = raw[key];
    if (typeof value === 'number' && Number.isInteger(value) && value > 0) intent[key] = value;
  }

  const subjectLabel = text('subjectLabel');
  if (subjectLabel !== undefined) intent.subjectLabel = subjectLabel;

  return intent;
}

export function setIntent(intent: Intent): void {
  pending = intent;
  for (const listener of listeners) listener(intent);
}

/** The pending intent, without taking it. */
export function peekIntent(): Intent | null {
  return pending;
}

/** Takes the pending intent, so it is acted on once. */
export function takeIntent(): Intent | null {
  const intent = pending;
  pending = null;
  return intent;
}

/** Called with every new intent; returns the unsubscribe. */
export function onIntent(listener: Listener): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}
