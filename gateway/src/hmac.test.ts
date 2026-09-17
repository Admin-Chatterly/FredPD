import { describe, expect, it } from 'vitest';

import { sign, verify } from './hmac';

const SECRET = 'test-secret';
const NOW = 1_800_000_000_000; // fixed clock, so these never flake
const TIMESTAMP = Math.floor(NOW / 1000);
const BODY = JSON.stringify({ action: 'role.add', discordId: '1', roleId: '2' });

function input(overrides: Partial<Parameters<typeof verify>[0]> = {}) {
  return {
    secret: SECRET,
    signature: sign(SECRET, TIMESTAMP, BODY),
    timestamp: String(TIMESTAMP),
    body: BODY,
    replayWindowSeconds: 30,
    now: NOW,
    ...overrides,
  };
}

describe('gateway HMAC', () => {
  it('accepts a correctly signed request', () => {
    expect(verify(input())).toEqual({ ok: true });
  });

  it('rejects a request signed with the wrong secret', () => {
    expect(verify(input({ signature: sign('other-secret', TIMESTAMP, BODY) }))).toEqual({
      ok: false,
      reason: 'bad_signature',
    });
  });

  it('rejects a tampered body', () => {
    expect(verify(input({ body: BODY.replace('role.add', 'role.remove') }))).toEqual({
      ok: false,
      reason: 'bad_signature',
    });
  });

  it('rejects a replay outside the window', () => {
    expect(verify(input({ now: NOW + 31_000 }))).toEqual({ ok: false, reason: 'expired' });
  });

  it('rejects a timestamp from the future, not just a stale one', () => {
    expect(verify(input({ now: NOW - 31_000 }))).toEqual({ ok: false, reason: 'expired' });
  });

  it('rejects a request with the timestamp moved into the window', () => {
    // The timestamp is inside the signed material, so shifting it breaks the
    // signature rather than buying a fresh window.
    const moved = TIMESTAMP + 60;
    expect(verify(input({ timestamp: String(moved), now: (moved + 1) * 1000 }))).toEqual({
      ok: false,
      reason: 'bad_signature',
    });
  });

  it('rejects missing headers', () => {
    expect(verify(input({ signature: undefined }))).toEqual({ ok: false, reason: 'malformed' });
    expect(verify(input({ timestamp: undefined }))).toEqual({ ok: false, reason: 'malformed' });
  });

  it('rejects a non-numeric timestamp', () => {
    expect(verify(input({ timestamp: 'soon' }))).toEqual({ ok: false, reason: 'malformed' });
  });
});
