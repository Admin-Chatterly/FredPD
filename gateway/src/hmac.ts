import { createHmac, timingSafeEqual } from 'node:crypto';

/**
 * Request signing for the FXServer link (spec 3.7).
 *
 * Both directions sign `<timestamp>.<body>` with the shared secret. The
 * timestamp is inside the signed material, so it cannot be moved to a fresh
 * window without invalidating the signature, which is what makes the replay
 * check meaningful.
 */

export const SIGNATURE_HEADER = 'x-fredpd-signature';
export const TIMESTAMP_HEADER = 'x-fredpd-timestamp';

export function sign(secret: string, timestamp: number, body: string): string {
  return createHmac('sha256', secret).update(`${timestamp}.${body}`).digest('hex');
}

export type VerifyResult =
  | { ok: true }
  | { ok: false; reason: 'malformed' | 'expired' | 'bad_signature' };

export interface VerifyInput {
  secret: string;
  signature: string | undefined;
  timestamp: string | undefined;
  body: string;
  replayWindowSeconds: number;
  /** Injectable so tests do not depend on the wall clock. */
  now?: number;
}

export function verify({
  secret,
  signature,
  timestamp,
  body,
  replayWindowSeconds,
  now = Date.now(),
}: VerifyInput): VerifyResult {
  if (typeof signature !== 'string' || typeof timestamp !== 'string') {
    return { ok: false, reason: 'malformed' };
  }

  const sentAt = Number.parseInt(timestamp, 10);
  if (!Number.isFinite(sentAt)) {
    return { ok: false, reason: 'malformed' };
  }

  // Absolute difference, so a clock running ahead is rejected too rather than
  // granting an unbounded future window.
  const ageSeconds = Math.abs(now / 1000 - sentAt);
  if (ageSeconds > replayWindowSeconds) {
    return { ok: false, reason: 'expired' };
  }

  const expected = Buffer.from(sign(secret, sentAt, body), 'utf8');
  const actual = Buffer.from(signature, 'utf8');

  // timingSafeEqual throws on a length mismatch, which would itself leak length.
  if (expected.length !== actual.length || !timingSafeEqual(expected, actual)) {
    return { ok: false, reason: 'bad_signature' };
  }

  return { ok: true };
}
