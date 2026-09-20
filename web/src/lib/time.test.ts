import { afterEach, describe, expect, it } from 'vitest';
import { formatDate, formatMoment, setDepartmentTimezone, toDate, toSeconds } from './time';

/**
 * The three shapes a timestamp arrives in, and the two that were read wrong.
 *
 * These assert against *local* time on purpose, which is why they build their
 * expectations from a `Date` rather than writing a literal: the suite has to
 * pass in a department running UTC+2 and in CI running UTC, and a fixed string
 * would only prove which one wrote it.
 */

/** The same instant, in each of the three forms the server sends. */
const INSTANT = new Date(2026, 8, 20, 21, 14, 5);
const MILLISECONDS = INSTANT.getTime();
const SECONDS = Math.floor(MILLISECONDS / 1000);

/** What a MariaDB DATETIME looks like as text: local, no zone marker. */
function asText(date: Date): string {
  const pad = (value: number) => String(value).padStart(2, '0');

  return (
    `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ` +
    `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`
  );
}

describe('formatMoment', () => {
  it('reads epoch seconds as seconds, not as milliseconds', () => {
    // The bug this exists for. `UNIX_TIMESTAMP` gives seconds; the old
    // formatters did `new Date(value)`, which is milliseconds, so every
    // timestamp on the custody screen and the query log rendered in 1970.
    expect(formatMoment(SECONDS)).toBe(formatMoment(INSTANT.getTime()));
    expect(toDate(SECONDS)?.getFullYear()).toBe(2026);
  });

  it('reads a fractional UNIX_TIMESTAMP, which a TIMESTAMP(3) column gives', () => {
    expect(formatMoment(SECONDS + 0.123)).toBe(formatMoment(SECONDS));
  });

  it('reads epoch milliseconds as milliseconds', () => {
    expect(toDate(MILLISECONDS)?.getFullYear()).toBe(2026);
    expect(formatMoment(MILLISECONDS)).toBe(formatMoment(asText(INSTANT)));
  });

  it('reads a DATETIME string as local time, the way MariaDB wrote it', () => {
    expect(formatMoment(asText(INSTANT))).toBe(formatMoment(SECONDS));
  });

  it('renders in local time, not UTC', () => {
    // RB 24:12's deadline is a *local* noon. A screen printing UTC beside it
    // is an hour or two out on the one figure an officer quotes to a
    // prosecutor. Asserted through the hour the platform itself reports, so
    // this holds wherever the suite runs.
    const local = new Date(2026, 0, 2, 3, 4, 0);

    expect(formatMoment(Math.floor(local.getTime() / 1000))).toBe('2026-01-02 03:04');
  });

  it('is empty for a moment that is not one', () => {
    expect(formatMoment(null)).toBe('');
    expect(formatMoment('')).toBe('');
    expect(formatMoment(Number.NaN)).toBe('');
    // Not the words "Invalid Date" on somebody's record.
    expect(formatMoment('not a date')).toBe('');
  });
});

describe('formatDate', () => {
  it('drops the time', () => {
    expect(formatDate(SECONDS)).toBe(formatMoment(SECONDS).slice(0, 10));
  });

  it('keeps a plain DATE column on its own day', () => {
    // A `YYYY-MM-DD` string parses as UTC midnight in every browser. Read back
    // in a timezone behind UTC that is the previous day, which would move
    // somebody's date of birth.
    expect(formatDate('1994-03-07')).toBe('1994-03-07');
  });
});

describe('the department timezone', () => {
  afterEach(() => setDepartmentTimezone(null));

  it('renders a moment in the department zone, not the machine one', () => {
    // 2026-07-01T10:00:00Z is midday in Stockholm (CEST, UTC+2). Whatever the
    // machine running this is set to, an officer reading a Swedish
    // department's custody log has to see the Swedish time.
    const instant = Date.UTC(2026, 6, 1, 10, 0, 0) / 1000;

    setDepartmentTimezone('Europe/Stockholm');
    expect(formatMoment(instant)).toBe('2026-07-01 12:00');

    setDepartmentTimezone('Pacific/Auckland');
    expect(formatMoment(instant)).toBe('2026-07-01 22:00');
  });

  it('follows daylight saving in that zone', () => {
    // The same wall clock either side of the change: +01:00 in January and
    // +02:00 in July, which a fixed offset could not do.
    setDepartmentTimezone('Europe/Stockholm');

    expect(formatMoment(Date.UTC(2026, 0, 15, 11, 0, 0) / 1000)).toBe('2026-01-15 12:00');
    expect(formatMoment(Date.UTC(2026, 6, 15, 10, 0, 0) / 1000)).toBe('2026-07-15 12:00');
  });

  it('falls back to the machine zone when the name is one Intl will not take', () => {
    // A typo in a convar must not take every clock in the interface down.
    setDepartmentTimezone('Europe/Stockholmm');

    expect(formatMoment(SECONDS)).toBe(formatMoment(asText(INSTANT)));
  });

  it('leaves a date-only column alone', () => {
    // A date of birth is not an instant. Shifted into another zone it moves a
    // day, on the record used to identify somebody.
    setDepartmentTimezone('Pacific/Auckland');

    expect(formatDate('1994-03-07')).toBe('1994-03-07');
  });
});

describe('toSeconds', () => {
  it('answers what the routes take, whatever arrived', () => {
    expect(toSeconds(SECONDS)).toBe(SECONDS);
    expect(toSeconds(MILLISECONDS)).toBe(SECONDS);
    expect(toSeconds(asText(INSTANT))).toBe(SECONDS);
    expect(toSeconds(null)).toBeNull();
  });
});
