import { t } from '../../lib/i18n';
import type { ErrorCode } from '@fredpd/schema';

/**
 * Rendering a refused route call (spec 3.5).
 *
 * Every route answers with the same envelope, and a refusal may carry `fields`:
 * the field the server objected to, and a short code saying why. Showing only
 * `error.invalid` throws that away and leaves the officer guessing which box is
 * wrong, so the envelope is kept whole and both halves are drawn.
 *
 * Nothing here decides what may be done — the server already refused. This is
 * how the refusal is read out loud (invariant 4).
 */

export interface Failure {
  err: ErrorCode;
  fields?: Record<string, string>;
}

/**
 * The reasons the routes in this area answer with.
 *
 * A closed set, because a code that has no locale key must not render as one:
 * `fieldError.collected` in the interface would be worse than the raw word. An
 * unknown code — a status name echoed back, say — is shown as it arrived, which
 * is visibly data rather than a missing translation.
 */
const REASONS = new Set([
  // The validator's own codes (server/core/validate.lua). Every route can
  // answer with these, so they belong here before any route-specific one:
  // without them a bounded field rejects with the raw English word in both
  // languages.
  'type',
  'too_short',
  'too_long',
  'too_small',
  'too_large',

  'required',
  'exists',
  'unknown',
  'cycle',
  'not_group_key',
  'not_permission_key',
  'not_model',
  'not_locale_key',
  'not_certification',
  'not_snowflake',
  'not_integer',
  'not_allowed',
  'not_supported',
  'not_elapsed',
  'nothing_to_change',
  'protected',
  'would_lock_out',
  'inherited_by_groups',
  'mapped_to_roles',
  'too_many',
  'released',

  // Optimistic locking. `stale` is the record itself having moved on;
  // `model_changed` is the permission model as a whole, which the group editor
  // takes a lock on because an edit anywhere in an inheritance chain can change
  // what an unrelated group grants.
  'stale',
  'model_changed',
]);

export interface FieldMessage {
  /** The server's field name, used as the key when looping. */
  name: string;
  label: string;
  reason: string;
}

/**
 * Pairs each rejected field with the label its input already carries.
 *
 * `labels` maps the server's field name to the locale key of the form label, so
 * the message points at a box the officer can see rather than at a column name.
 * A field with no label falls back to its own name.
 */
export function fieldList(
  failure: Failure | null,
  labels: Record<string, string>,
): FieldMessage[] {
  const fields = failure?.fields;
  if (!fields) return [];

  return Object.entries(fields).map(([name, code]) => ({
    name,
    label: labels[name] ? t(labels[name]) : name,
    reason: REASONS.has(code) ? t(`fieldError.${code}`) : code,
  }));
}
