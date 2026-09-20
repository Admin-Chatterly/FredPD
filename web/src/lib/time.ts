import type { Moment } from './types';

/**
 * Rendering a server timestamp (spec 6.3).
 *
 * One formatter for the whole interface, because a timestamp arrives in three
 * shapes and two of them were being read wrong.
 *
 * **Epoch seconds.** `frihet`, `tvangsmedel`, `spaning` and `query` select
 * their timestamps through `UNIX_TIMESTAMP(...)`, which is *seconds*. Every
 * screen that had its own formatter did `new Date(value)`, which is
 * *milliseconds* — so a gripande three hours old rendered as `1970-01-21`, on
 * the chain, in the custody log, and on the query log. No test caught it
 * because the fixtures send ISO strings, which take the other branch.
 *
 * **Epoch milliseconds.** `persons`, `registry` and `anmalan` select DATETIME
 * columns, which oxmysql hands over as a string or as epoch milliseconds
 * depending on its date handling. Both happen; `Moment` says so.
 *
 * The two are told apart by magnitude and nothing else. `1e11` is the only
 * threshold that works for both: as milliseconds it is 1973, and as seconds it
 * is the year 5138. A police record carries neither.
 *
 * **And it renders local time.** The old formatters went through
 * `toISOString()`, which is UTC. RB 24:12's deadline is *klockan tolv* in the
 * department's own timezone, so a UTC clock beside it puts an officer an hour
 * or two out on the one figure they quote to a prosecutor — and a custody log
 * that disagrees with the wall clock in the custody suite is worse than no
 * custody log.
 */

/** Below this, a number is seconds; at or above it, milliseconds. */
const MILLISECOND_FLOOR = 1e11;

/**
 * The formatter for the department's timezone, from `session.get`.
 *
 * **Not the browser's zone.** A player in Brisbane reading a Swedish
 * department's custody log wants the Swedish time: the record is a statement
 * about when something happened *there*, and RB 24:12's deadline is a local
 * noon in that same zone. Until the session arrives — and if the configured
 * name is one `Intl` will not take — this stays null and the machine's own
 * zone is used, which is the best guess available and never throws.
 *
 * Built once per zone rather than once per cell. `Intl.DateTimeFormat`'s
 * constructor is the expensive part by a long way: measured at ~70 µs to
 * construct and format against ~2 µs to format with one already built, a
 * factor of thirty-five. Every timestamp in the interface goes through here by
 * design, so a fifty-row list was paying seven milliseconds for nothing.
 */
let formatter: Intl.DateTimeFormat | null = null;

/**
 * `sv-SE` is not a style choice: its date format is ISO-8601, which is what
 * every timestamp in this interface is written in, so the output needs no
 * reassembling beyond dropping the separator.
 */
function buildFormatter(zone: string): Intl.DateTimeFormat {
  return new Intl.DateTimeFormat('sv-SE', {
    timeZone: zone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hour12: false,
  });
}

export function setDepartmentTimezone(zone: string | null | undefined): void {
  if (!zone) {
    formatter = null;

    return;
  }

  try {
    // Asking `Intl` is the only way to find out whether it knows the name, and
    // a bad convar must not take the interface's clocks down with it. The
    // formatter built to ask the question is the one that is kept.
    const candidate = buildFormatter(zone);
    candidate.format(new Date());

    formatter = candidate;
  } catch {
    formatter = null;
  }
}

/** A moment in the department's zone, or in this machine's if none is set. */
function inZone(date: Date): string {
  if (!formatter) {
    const pad = (value: number) => String(value).padStart(2, '0');

    return (
      `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ` +
      `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`
    );
  }

  // `sv-SE` separates the date and the time with a space, but a narrow
  // no-break space or a comma appears in some ICU builds. Normalised rather
  // than assumed, because the callers slice by index.
  return formatter.format(date).replace(',', '').replace(/\s+/g, ' ');
}

/**
 * A `Moment` as a `Date`, or null when there is nothing to render.
 *
 * A date that does not parse comes back null rather than as `Invalid Date`, so
 * a malformed column renders as an empty cell instead of the words "Invalid
 * Date" on somebody's record.
 */
export function toDate(value: Moment): Date | null {
  if (value === null || value === undefined || value === '') return null;

  if (typeof value === 'number') {
    if (!Number.isFinite(value)) return null;

    return new Date(Math.abs(value) < MILLISECOND_FLOOR ? value * 1000 : value);
  }

  // A DATETIME as MariaDB writes it — `2026-09-20 21:14:05` — has no timezone
  // and is already local. `Date` parses the `T` form as local too, and only
  // the `Z` form as UTC, so replacing the space is enough and is what keeps a
  // string column and a seconds column reading the same.
  //
  // A **date-only** string is the exception and has to be spelled out: ES
  // parses `1994-03-07` as UTC midnight, which in any timezone behind UTC
  // reads back as the 6th — a date of birth off by a day, on a record used to
  // identify somebody.
  const text = /^\d{4}-\d{2}-\d{2}$/.test(value) ? `${value}T00:00:00` : value.replace(' ', 'T');

  const parsed = new Date(text);

  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

/**
 * `2026-09-20 21:14` — the department's clock, to the minute.
 *
 * Minutes are as fine as any record in this system needs: a custody log, a
 * decision, a query. Seconds would be noise in a column an officer scans.
 */
export function formatMoment(value: Moment): string {
  const date = toDate(value);
  if (!date) return '';

  return inZone(date).slice(0, 16);
}

/**
 * `2026-09-20` — a DATE column, which carries no time worth printing.
 *
 * A plain `YYYY-MM-DD` is returned as it arrived rather than put through a
 * zone. A date of birth is not an instant: shifting it into another timezone
 * is how somebody's birthday moves a day on their own record.
 */
export function formatDate(value: Moment): string {
  if (typeof value === 'string' && /^\d{4}-\d{2}-\d{2}/.test(value)) return value.slice(0, 10);

  const date = toDate(value);
  if (!date) return '';

  return inZone(date).slice(0, 10);
}

/**
 * Epoch **seconds** for a moment, which is what every write route takes.
 *
 * The server speaks seconds throughout (`os.time()`), so a screen computing a
 * span to send back has to as well.
 */
export function toSeconds(value: Moment): number | null {
  const date = toDate(value);

  return date ? Math.floor(date.getTime() / 1000) : null;
}
