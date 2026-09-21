import { createHmac, randomUUID, timingSafeEqual } from 'node:crypto';

/**
 * Signed upload and download tokens for the media store (spec 3.7, 9, 11).
 *
 * A `media_ref` on a database row is a reference and never a URL (invariant
 * 9): nothing about it is fetchable on its own. What makes a file reachable
 * is a token, scoped to one ref, one action and one expiry, signed with a
 * subkey derived from the FXServer link's own secret (`deriveKey`,
 * `config.ts`) so a leaked media token cannot be replayed against `/fx`.
 *
 * The signed material mirrors `hmac.ts`'s reasoning: the expiry travels
 * *inside* what is signed, so a token cannot be moved to a fresh window
 * without invalidating the signature.
 */

export type MediaAction = 'upload' | 'download';

export interface MediaToken {
  mediaRef: string;
  action: MediaAction;
  /** Epoch seconds. */
  expiresAt: number;
  signature: string;
}

function materialFor(mediaRef: string, action: MediaAction, expiresAt: number): string {
  return `${mediaRef}.${action}.${expiresAt}`;
}

/** A fresh, unguessable reference. Never derived from anything a caller sent. */
export function newMediaRef(): string {
  return `media_${randomUUID()}`;
}

export function signMediaToken(
  key: string,
  mediaRef: string,
  action: MediaAction,
  expiresAt: number,
): string {
  return createHmac('sha256', key).update(materialFor(mediaRef, action, expiresAt)).digest('hex');
}

export type MediaTokenResult =
  | { ok: true }
  | { ok: false; reason: 'malformed' | 'expired' | 'bad_signature' };

/**
 * Checks a token against the ref and action a route is about to serve.
 *
 * The ref and action are never read *from* the token — they come from the
 * URL the caller reached, and this only answers whether the signature
 * authorises exactly that ref and that action. A token good for uploading
 * one file must not also be good for downloading a different one.
 */
export function verifyMediaToken(
  key: string,
  mediaRef: string,
  action: MediaAction,
  expiresAt: number,
  token: string | undefined,
  now: number = Math.floor(Date.now() / 1000),
): MediaTokenResult {
  if (typeof token !== 'string' || token === '') return { ok: false, reason: 'malformed' };
  if (!Number.isFinite(expiresAt)) return { ok: false, reason: 'malformed' };
  if (now > expiresAt) return { ok: false, reason: 'expired' };

  const expected = Buffer.from(signMediaToken(key, mediaRef, action, expiresAt), 'utf8');
  const actual = Buffer.from(token, 'utf8');

  if (expected.length !== actual.length || !timingSafeEqual(expected, actual)) {
    return { ok: false, reason: 'bad_signature' };
  }

  return { ok: true };
}
