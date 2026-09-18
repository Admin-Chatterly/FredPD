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
  // Not `released`: an evidence item's status is `released` too, and the codes
  // share one namespace regardless of which field carried them, so the item
  // would have been explained as a scene.
  'scene_released',
  // A trace the grid has no owner row for. Collection refuses rather than
  // writing an owner row the CHECK forbids.
  'unattributed',

  // Optimistic locking. `stale` is the record itself having moved on;
  // `model_changed` is the permission model as a whole, which the group editor
  // takes a lock on because an edit anywhere in an inheritance chain can change
  // what an unrelated group grants.
  'stale',
  'model_changed',

  // The registers and the name index (spec 7.2-7.5). `clearance` is the
  // write-side half of 4.5's ladder: the record would sit above what the
  // writer may read back. `field_forbidden` is a field the reader was never
  // shown, arriving in a write anyway. `format` is a date that is not a date.
  'clearance',
  'field_forbidden',
  'format',

  // The four firearm statuses a transfer refuses, arriving as the `status`
  // field code (registry/routes.lua). A weapon that is lost, stolen, seized or
  // destroyed cannot be transferred, because the transfer would write
  // `registered` over the fact.
  'lost',
  'stolen',
  'seized',
  'destroyed',

  // Dispatch (spec 7.16-7.18). A CAD refusal is read in a hurry, often by
  // somebody holding a radio, so each of these says which fact stopped the
  // write rather than that something did.
  //
  // `call_cleared` and `call_cancelled` are prefixed for the reason
  // `scene_released` is: `cleared` is an intel person's status and `cancelled`
  // is a lab request's, and the codes share one namespace whatever field
  // carried them. A call the dispatcher already closed would otherwise be
  // explained in the words of a register nobody was looking at.
  'call_cleared',
  'call_cancelled',

  // The unit is already on this call, or is not on it. Both arrive on the
  // dispatch form: adding a unit twice, taking one off that left, or naming a
  // lead unit that the same dispatch did not put on the call.
  'already_assigned',
  'not_assigned',

  // The officer behind the unit is signed off (7.1 duty state), and
  // `unavailable` is the unit's own status refusing the work -- out of service,
  // or already on something the dispatcher has not seen. Two codes because the
  // fix differs: one is "sign on", the other is "clear what you are on".
  'off_duty',
  'unavailable',

  // No `fpd_units` row at all: the session never signed on to a unit, so there
  // is nothing to attach to a call, to move, or to put in distress. Different
  // from `off_duty`, which is a unit that exists and is not working.
  'no_unit',

  // An emergency call cannot be cleared until a supervisor has acknowledged it
  // (7.16). The refusal names the field so the card can say what is missing
  // rather than greying the button out with no reason.
  'needs_acknowledgement',

  // A beat, a placement or a hotlist entry that exists but has been switched
  // off. Distinct from `unknown`, because "there is no such beat" and "that
  // district was retired last week" are different mistakes.
  'disabled',

  // ------------------------------------------------ the M2 records workflow

  // Brottskatalogen (7.10). A straffskala that is not one, a citation with
  // half its parts, a fixed term above the eighteen years BrB 26:1 allows.
  'straffskala',
  'incomplete_citation',
  'over_max',

  // Anmälan (7.7). `own_report` is the one that matters most: it is the rule
  // no permission reaches, and without a key here the panel prints the literal
  // word `own_report` under a message about Discord roles — which is exactly
  // the wrong conclusion for the officer to draw.
  'own_report',
  'locked',
  'under_review',
  'not_author',
  'not_submitted',
  'not_submittable',

  // Tilläggsuppgifter (7.7). The chain rules the schema cannot hold.
  'self_parent',
  'too_deep',

  // Charges. `stage_unavailable` is BrB 23: the statute does not make the
  // attempt punishable for this offence.
  'stage_unavailable',
  'length_mismatch',

  // Förundersökning (7.8) and frihetsberövande (7.9). `wrong_capacity` is an
  // officer trying to take the åklagare's decision, which is a different
  // refusal from not holding a grant.
  'not_ledare',
  'fu_closed',
  'wrong_capacity',
  'already_released',

  // Tvångsmedel (7.12). A measure aimed at the wrong kind of target, and the
  // three ways one stops authorising anything.
  'not_a_place',
  'not_a_person',
  'upphavd',
  'not_yet',
  'expired',
  'cancelled',

  // Spaningsuppdrag (7.13).
  'required_without_target',
  'resolved',
  'no_expiry',
  'out_of_range',

  // Record-level access (4.5): a classification above the writer's clearance.
  'over_clearance',
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
