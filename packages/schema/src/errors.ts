/**
 * Route error codes (spec 3.5).
 *
 * This list is the contract between three places that must never disagree: the
 * Lua route layer that returns a code, the NUI that maps it to a message, and
 * the locale files that hold the message. `error.<code>` exists in every locale
 * file, and `pnpm i18n:check` fails when one is missing.
 */
export const ERROR_CODES = [
  'no_session',
  'forbidden',
  'context',
  'rate_limited',
  'invalid',
  'not_found',
  'conflict',
  'restricted',
  'stale_permissions',
  'internal',
] as const;

export type ErrorCode = (typeof ERROR_CODES)[number];

export function isErrorCode(value: string): value is ErrorCode {
  return (ERROR_CODES as readonly string[]).includes(value);
}
