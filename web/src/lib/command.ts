/**
 * The MDT command line (Appendix F): a line typed in the title bar, turned
 * into what the officer would otherwise click through to.
 *
 * Parsing only, and pure, so it is tested without a browser. Every command
 * becomes either a navigation (an intent, which opens a screen the session
 * could already open) or an ordinary route the server checks like any other
 * (invariant 4). Nothing here decides what anybody may do.
 *
 * English verbs and the Swedish aliases the appendix lists are both accepted,
 * whichever language the MDT is drawn in: an officer types what they learned.
 */

import { CALL_DISPOSITIONS } from '@fredpd/schema';

export type Command =
  | { kind: 'query'; type?: string; term: string }
  | { kind: 'status'; status: string }
  | { kind: 'attach' }
  | { kind: 'clear'; disposition: string }
  | {
      kind: 'invalid';
      reason: 'empty' | 'needs_term' | 'unknown_status' | 'unknown_disposition' | 'not_built';
    };

/** Query verbs: `P ABC123`, `REG ABC123`, `N Doe, John`. */
const QUERY_VERBS: Record<string, string> = {
  P: 'plate',
  REG: 'plate',
  N: 'person',
  S: 'firearm',
  VAP: 'firearm',
  PH: 'phone',
  TEL: 'phone',
  A: 'address',
  ADR: 'address',
  VIN: 'vin',
};

/** `ST <code>`: the unit status codes on the radio (Appendix F). */
export const STATUS_CODES: Record<string, string> = {
  AV: 'available',
  ER: 'en_route',
  OS: 'on_scene',
  BU: 'busy',
  TR: 'transporting',
  ST: 'at_station',
  OOS: 'out_of_service',
};

/** Appendix F verbs with nothing behind them yet: open a call, report or
 * evidence item by number, send a message, create a record. */
const RESERVED = new Set(['C', 'H', 'R', 'AN', 'E', 'B', 'MSG', 'MED', 'NEW', 'NY']);

/** `CLR` with no code clears as handled on scene: the commonest ending. */
const DEFAULT_DISPOSITION = 'handled_on_scene';

/** Short codes for the dispositions, beside their full names. */
const DISPOSITION_CODES: Record<string, string> = {
  HOS: 'handled_on_scene',
  RPT: 'report_taken',
  ARR: 'arrest_made',
  CIT: 'citation_issued',
  WARN: 'warning_given',
  GOA: 'gone_on_arrival',
  UTL: 'unable_to_locate',
  UNF: 'unfounded',
};

export function parseCommand(line: string): Command {
  const text = line.trim();
  if (text === '') return { kind: 'invalid', reason: 'empty' };

  const space = text.search(/\s/);
  const verb = (space === -1 ? text : text.slice(0, space)).toUpperCase();
  const rest = space === -1 ? '' : text.slice(space).trim();

  const type = QUERY_VERBS[verb];
  if (type) {
    if (rest === '') return { kind: 'invalid', reason: 'needs_term' };
    return { kind: 'query', type, term: rest };
  }

  if (verb === 'ST') {
    const status = STATUS_CODES[rest.toUpperCase()];
    return status ? { kind: 'status', status } : { kind: 'invalid', reason: 'unknown_status' };
  }

  if (verb === 'ATT' || verb === 'TILL') {
    return { kind: 'attach' };
  }

  if (verb === 'CLR' || verb === 'KLAR') {
    if (rest === '') return { kind: 'clear', disposition: DEFAULT_DISPOSITION };

    const code = rest.toUpperCase();
    const named = rest.toLowerCase().replace(/\s+/g, '_');
    const disposition =
      DISPOSITION_CODES[code] ??
      ((CALL_DISPOSITIONS as readonly string[]).includes(named) ? named : undefined);

    return disposition ? { kind: 'clear', disposition } : { kind: 'invalid', reason: 'unknown_disposition' };
  }

  // Verbs Appendix F names that are not built yet. Said so, rather than run
  // as a search for "MSG 1-ADAM-12 on my way", which would be logged.
  if (RESERVED.has(verb)) return { kind: 'invalid', reason: 'not_built' };

  // Anything else is a search: a plate, a name or a number, and the query
  // screen works out which.
  return { kind: 'query', term: text };
}
