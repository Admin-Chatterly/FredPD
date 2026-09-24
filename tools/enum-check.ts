import { readdir, readFile } from 'node:fs/promises';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// By path rather than by package name: `tools/` is not a workspace package and
// does not depend on `@fredpd/schema`, so the bare specifier does not resolve
// here the way it does from `web/` or `gateway/`.
import * as enums from '../packages/schema/src/index.ts';

/**
 * Checks that the database and the code agree about what a code value is.
 *
 * A column with a `CHECK (col IN (…))` and an exported enum are two spellings of
 * one vocabulary, written in two languages, in two files, by two people. Nothing
 * else in CI compares them: `pnpm check` type-checks the TypeScript, `i18n:check`
 * reads the locale files, `wiring-check` reads the routes, and busted never
 * touches SQL. So a single disagreement passes every gate and fails at runtime,
 * as MariaDB error 4025, on the first write — and only on the branch that
 * happens to use the disputed value.
 *
 * This has already cost a milestone. The M4 dispatch foundation shipped three of
 * them at once: `enroute` in the CHECK against `en_route` in the enum, which is
 * every unit going en route; a call-log constraint listing categories against an
 * enum listing events, which is the opening line of every call's narrative; and
 * a hotlist constraint that rejected the two reasons spec 7.18 names first.
 *
 * It fails on:
 *
 *   1. a paired constraint and enum whose value sets differ, in either
 *      direction — a value the database refuses, or one it accepts that no
 *      client can send;
 *   2. a `CHECK (col IN (…))` in a migration that is in neither table below, so
 *      a new code column has to be a decision somebody writes down rather than
 *      an omission nobody notices;
 *   3. a pairing that names an enum `packages/schema` does not export.
 *
 * What it deliberately does not do is require every enum to have a constraint.
 * Most should not have one: `0005_records.sql` argues the case at length — a
 * code list that lives only in the service fails at the call site with its name
 * in the message, while a CHECK fails in the database with a constraint name and
 * no clue which value was wrong. This file exists for the columns where somebody
 * chose a CHECK anyway.
 */

const here = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(here, '..');
const MIGRATIONS = join(REPO, 'database', 'migrations');

/**
 * Constraint name -> the exported enum it must agree with.
 *
 * The enum name is the export in `packages/schema`. Numeric enums are compared
 * as strings, because SQL writes them quoted.
 */
const PAIRED: Record<string, keyof typeof enums> = {
  // Record-level access (0001, 0005). One vocabulary, eleven columns: every
  // classified table repeats it, so a drift here would be eleven drifts.
  ck_fpd_intel_persons_class: 'CLASSIFICATIONS',
  ck_fpd_intel_orgs_class: 'CLASSIFICATIONS',
  ck_fpd_intel_cases_class: 'CLASSIFICATIONS',
  ck_fpd_intel_notes_class: 'CLASSIFICATIONS',
  ck_fpd_intel_vehicles_class: 'CLASSIFICATIONS',
  ck_fpd_intel_evidence_class: 'CLASSIFICATIONS',
  ck_fpd_classifications_level: 'CLASSIFICATIONS',
  ck_fpd_persons_class: 'CLASSIFICATIONS',
  ck_fpd_person_photos_class: 'CLASSIFICATIONS',
  ck_fpd_person_cautions_class: 'CLASSIFICATIONS',
  ck_fpd_vehicles_class: 'CLASSIFICATIONS',
  ck_fpd_vehicle_flags_class: 'CLASSIFICATIONS',
  ck_fpd_firearms_class: 'CLASSIFICATIONS',
  ck_fpd_calls_class: 'CLASSIFICATIONS',

  // Intelligence (0001, spec 10).
  ck_fpd_intel_persons_status: 'INTEL_PERSON_STATUSES',
  ck_fpd_intel_orgs_status: 'INTEL_ORG_STATUSES',
  ck_fpd_intel_cases_status: 'INTEL_CASE_STATUSES',
  ck_fpd_intel_notes_confidence: 'INTEL_CONFIDENCE',

  // Evidence and the lab (0002, spec 8).
  ck_fpd_scenes_status: 'SCENE_STATUSES',
  ck_fpd_evidence_seal: 'EVIDENCE_SEAL_STATES',
  ck_fpd_evidence_status: 'EVIDENCE_STATUSES',
  ck_fpd_lab_requests_priority: 'LAB_PRIORITIES',
  ck_fpd_lab_requests_status: 'LAB_REQUEST_STATUSES',
  ck_fpd_lab_analyses_status: 'LAB_ANALYSIS_STATUSES',

  // The registers (0005, spec 7.2-7.5).
  ck_fpd_person_cautions_kind: 'PERSON_CAUTION_KINDS',
  ck_fpd_vehicles_registration: 'VEHICLE_REGISTRATION_STATUSES',
  ck_fpd_vehicles_insurance: 'VEHICLE_INSURANCE_STATUSES',
  ck_fpd_vehicle_flags_kind: 'VEHICLE_FLAG_KINDS',
  ck_fpd_firearms_status: 'FIREARM_STATUSES',
  ck_fpd_firearm_events_event: 'FIREARM_EVENTS',

  // Dispatch (0007, spec 7.16-7.18).
  ck_fpd_calls_status: 'CALL_STATUSES',
  ck_fpd_units_status: 'UNIT_STATUSES',
  ck_fpd_call_log_type: 'CALL_LOG_KINDS',
  ck_fpd_call_links_target: 'CALL_LINK_KINDS',
  ck_fpd_call_links_role: 'CALL_LINK_ROLES',
  ck_fpd_hotlist_reason: 'HOTLIST_REASONS',
  ck_fpd_broadcasts_kind: 'BROADCAST_KINDS',
  ck_fpd_brott_grad: 'BROTT_GRADER',

  // Anmälan och förundersökning (0009).
  ck_fpd_anmalan_status: 'ANMALAN_STATUSES',
  ck_fpd_anmalan_class: 'CLASSIFICATIONS',
  ck_fpd_anmalan_personer_roll: 'ANMALAN_ROLLER',
  ck_fpd_anmalan_brott_stage: 'BROTT_STAGES',
  ck_fpd_fu_status: 'FU_STATUSES',
  ck_fpd_fu_ledare_kind: 'FU_LEDARE_KINDS',
  ck_fpd_fu_class: 'CLASSIFICATIONS',

  // Frihetsberövande (0010).
  ck_fpd_frihet_status: 'FRIHET_STATUSES',
  ck_fpd_frihet_class: 'CLASSIFICATIONS',
  ck_fpd_frihet_brott_stage: 'BROTT_STAGES',

  // Tvångsmedel och efterlysning (0011).
  ck_fpd_tvang_kind: 'TVANG_KINDS',
  ck_fpd_tvang_target: 'TVANG_TARGETS',
  ck_fpd_tvang_decider: 'TVANG_DECIDERS',
  ck_fpd_tvang_class: 'CLASSIFICATIONS',
  ck_fpd_efterlysning_grund: 'EFTERLYSNING_GRUNDER',
  ck_fpd_efterlysning_class: 'CLASSIFICATIONS',

  // Spaningsuppdrag (0012).
  ck_fpd_spaning_target: 'SPANING_TARGETS',
  ck_fpd_spaning_class: 'CLASSIFICATIONS',

  // Secret coercive measures (0015, spec 9).
  ck_fpd_hak_target: 'HAK_TARGETS',
  ck_fpd_hak_method: 'HAK_METHODS',
  ck_fpd_hak_status: 'HAK_STATUSES',
  ck_fpd_hak_class: 'CLASSIFICATIONS',
  ck_fpd_hak_intercepts_class: 'CLASSIFICATIONS',

  // Åtal och dom (0016, spec 7.20).
  ck_fpd_atal_beslut: 'ATAL_BESLUT',
  ck_fpd_atal_disposition: 'ATAL_DISPOSITIONS',
  ck_fpd_atal_class: 'CLASSIFICATIONS',
  ck_fpd_atal_brott_stage: 'BROTT_STAGES',

  // Personnel (0017, spec 7.22-7.24).
  ck_fpd_discipline_class: 'CLASSIFICATIONS',

  // Personnel issue gates (0027, spec 7.22-7.23).
  ck_fpd_personnel_issue_gate_kind: 'PERSONNEL_ISSUE_KINDS',

  // Booking (0018, spec 7.9).
  ck_fpd_booking_class: 'CLASSIFICATIONS',

  // Ordningsbot (0019, spec 7.11).
  ck_fpd_ordningsbot_status: 'ORDNINGSBOT_STATUSES',
  ck_fpd_ordningsbot_class: 'CLASSIFICATIONS',

  // Impound (0020, spec 7.15).
  ck_fpd_impound_reason: 'IMPOUND_HELD_REASONS',

  // Field interviews and stops (0035, spec 7.14).
  ck_fpd_fi_cards_reason: 'FI_REASONS',
  ck_fpd_fi_cards_class: 'CLASSIFICATIONS',
  ck_fpd_stops_kind: 'STOP_KINDS',
  ck_fpd_stops_reason: 'STOP_REASONS',
  ck_fpd_stops_search: 'STOP_SEARCHES',
  ck_fpd_stops_result: 'STOP_RESULTS',
  ck_fpd_stops_class: 'CLASSIFICATIONS',

  // Locations and premises (0034, spec 7.6).
  ck_fpd_locations_kind: 'LOCATION_KINDS',
  ck_fpd_locations_class: 'CLASSIFICATIONS',
  ck_fpd_location_hazards_kind: 'LOCATION_HAZARD_KINDS',
  ck_fpd_location_keyholders_role: 'LOCATION_KEYHOLDER_ROLES',
  ck_fpd_impound_class: 'CLASSIFICATIONS',
};

/**
 * Constraints whose values are deliberately not an exported enum, each with the
 * reason. "It is not a route input" is the usual one: a value the server writes
 * and a client never sends does not need a shape a client is validated against.
 *
 * Adding to this list is how a new code column is excused, and the reason is the
 * point of the list — "no enum" is exactly what a forgotten enum looks like too.
 */
const UNPAIRED: Record<string, string> = {
  // What the court decided at the häktningsförhandling (0010). Written by
  // `Repo.decide` from the transition it just made, never sent: the route that
  // records a häktning is the court's, and the outcome follows from which
  // route was called rather than from a field on it.
  ck_fpd_frihet_beslut: 'what the court decided; written by the transition, never sent',

  // The status a version snapshot was taken at (0009). The same four values as
  // `ck_fpd_anmalan_status`, and deliberately not paired with the enum: this
  // column is written by `Repo.transition` from the row it just moved, inside
  // the same transaction, and no route input carries it. Pairing it would
  // claim a client sends a version's status, which is the one thing that must
  // never be true of an append-only version table.
  ck_fpd_anmalan_versions_status: 'the status a snapshot was taken at; copied from the row by the transition, never sent',

  // Access control internals (0005). The stub modes and the grantee kind are
  // read and written by `modules/access`, never by a route: what a client sends
  // is a record and a compartment, and the module decides the rest.
  ck_fpd_compartments_stub: 'how a compartment hides a record; chosen in the compartment editor, not sent',
  ck_fpd_classifications_stub: 'as above, for a classification level',
  ck_fpd_record_grants_subject: 'whether a grant names a Discord role or a user; derived by the module',

  // Index kinds (0002, 0005). These name which reference index a row belongs to
  // and are written by the lab and the booking flow. `LAB_ANALYSES` is the
  // neighbouring enum and is deliberately not the same list: an analysis is
  // something the lab runs, an index is somewhere a profile is filed.
  ck_fpd_forensic_index_kind: 'which reference index a profile is filed in; written by the lab, never sent',
  ck_fpd_person_biometrics_kind: 'which biometric an index row holds; written at booking, never sent',

  // Person record shape (0005). Free-form enough that the allowlist lives in
  // `persons/service.lua`, where an unknown value fails at the call site with
  // its name in the message rather than as a constraint name.
  ck_fpd_person_aliases_kind: 'what kind of other name this is; the service owns the list (0005 argues why)',
  ck_fpd_person_photos_kind: 'what a photograph shows; the service owns the list',

  // The unified query and hot-file confirmation (0005, 0006). Both are written
  // from what the server just did, and neither appears in a route input.
  ck_fpd_query_log_type: 'what was queried; derived from the route that ran, never sent',
  ck_fpd_hotfile_confirmations_hit_type: 'what kind of hot-file hit was confirmed; derived server-side',
  ck_fpd_hotfile_confirmations_record_type: 'which register the hit came from; derived server-side',
  ck_fpd_hotfile_confirmations_outcome: 'how the confirmation ended; derived server-side',

  // Dispatch (0007).
  ck_fpd_beats_kind:
    'a beat or a district, written by the placement editor and never sent by a client',
  ck_fpd_calls_source:
    'how a call was raised. The server decides it -- a dispatcher, the phone bridge, the ' +
    'CreateCall export, the panic button, an ALPR hit -- and no route accepts it',
  ck_fpd_alpr_reads_camera:
    'which camera read the plate, supplied by the radar bridge rather than by a route',
};

interface Constraint {
  column: string;
  values: Set<string>;
  /** The column's VARCHAR width, when it has one. */
  width: number | undefined;
}

let failures = 0;

function fail(message: string): void {
  console.error(`  - ${message}`);
  failures += 1;
}

/** Lines beginning `--`, removed so a commented-out constraint is not read. */
function withoutComments(source: string): string {
  return source.replaceAll(/--[^\n]*/g, '');
}

/**
 * Every `CONSTRAINT name CHECK (col IN (…))` in one migration.
 *
 * The list may wrap over several lines, which every multi-value constraint in
 * this repository does, so the value list is matched across newlines and then
 * split rather than read token by token.
 */
function inListConstraints(source: string): Map<string, Constraint> {
  const found = new Map<string, Constraint>();
  const clean = withoutComments(source);

  // Split on CREATE TABLE first, so a column's width is read from the table the
  // constraint is actually in. Matching by column name alone across the whole
  // file is wrong and quietly so: `status` is VARCHAR(32) on one table and
  // VARCHAR(16) on another in the same migration, and taking the narrower one
  // reported a shipped, correct table as broken. A checker that cries wolf is
  // worse than no checker, because the next real finding gets waved through.
  const blocks = clean.split(/CREATE\s+TABLE/i).slice(1);

  const pattern =
    /CONSTRAINT\s+`([a-z0-9_]+)`\s+CHECK\s*\(\s*`([a-z0-9_]+)`\s+IN\s*\(([^)]*)\)/gi;

  for (const block of blocks) {
    const widths = new Map<string, number>();
    for (const declared of block.matchAll(/`([a-z0-9_]+)`\s+VARCHAR\((\d+)\)/gi)) {
      const column = declared[1];
      const width = Number(declared[2]);
      if (column === undefined || Number.isNaN(width)) continue;
      if (!widths.has(column)) widths.set(column, width);
    }

    for (const match of block.matchAll(pattern)) {
      const name = match[1];
      const column = match[2];
      const body = match[3];
      if (name === undefined || column === undefined || body === undefined) continue;

      const values = new Set<string>();
      for (const quoted of body.matchAll(/'([^']*)'/g)) {
        if (quoted[1] !== undefined) values.add(quoted[1]);
      }

      if (values.size > 0) found.set(name, { column, values, width: widths.get(column) });
    }
  }

  return found;
}

function describe(values: Set<string>): string {
  return [...values].sort().map((value) => `'${value}'`).join(', ');
}

console.log('enums: every CHECK list matches the enum the code sends');

const constraints = new Map<string, Constraint & { file: string }>();

for (const entry of (await readdir(MIGRATIONS)).sort()) {
  if (!entry.endsWith('.sql')) continue;

  const file = join(MIGRATIONS, entry);
  const source = await readFile(file, 'utf8');

  for (const [name, constraint] of inListConstraints(source)) {
    // A later migration may redefine a constraint it dropped. The last one wins,
    // which is the one a freshly migrated database ends up with.
    constraints.set(name, { ...constraint, file: relative(REPO, file) });
  }
}

if (constraints.size === 0) fail('database/migrations: found no CHECK … IN (…) constraints at all');

for (const [name, { column, values, width, file }] of constraints) {
  // Does every value the constraint allows actually fit the column it guards?
  // A vocabulary can agree perfectly and still be unstorable: `attempt_to_locate`
  // is seventeen characters, and it shipped in a VARCHAR(16), where MariaDB
  // rejects it with error 1406 under strict mode and silently truncates it into
  // a CHECK failure without. Set comparison cannot see that, so it is measured.
  if (width !== undefined) {
    const overlong = [...values].filter((value) => value.length > width);

    if (overlong.length > 0) {
      fail(
        `${file}: '${name}' allows ${describe(new Set(overlong))} in \`${column}\`, which is ` +
          `VARCHAR(${width}) — too long to store, so every write of those fails`,
      );
    }
  }

  const enumName = PAIRED[name];

  if (enumName === undefined) {
    if (UNPAIRED[name] !== undefined) continue;

    fail(
      `${file}: '${name}' constrains a column to ${describe(values)}, and nothing says which enum ` +
        `that is. Pair it in PAIRED, or record in UNPAIRED why no client ever sends the value`,
    );
    continue;
  }

  const exported = enums[enumName] as readonly (string | number)[] | undefined;

  if (!Array.isArray(exported)) {
    fail(`tools/enum-check.ts: '${name}' is paired with '${enumName}', which packages/schema does not export`);
    continue;
  }

  const declared = new Set(exported.map((value) => String(value)));

  const refused = [...declared].filter((value) => !values.has(value));
  const unreachable = [...values].filter((value) => !declared.has(value));

  if (refused.length > 0) {
    fail(
      `${file}: '${name}' refuses ${describe(new Set(refused))}, which '${enumName}' lets a client ` +
        `send — the write fails in the database, not at the door`,
    );
  }

  if (unreachable.length > 0) {
    fail(
      `${file}: '${name}' accepts ${describe(new Set(unreachable))}, which '${enumName}' does not ` +
        `contain — nothing can ever store those values`,
    );
  }
}

for (const [name, enumName] of Object.entries(PAIRED)) {
  if (!constraints.has(name)) {
    fail(
      `tools/enum-check.ts: '${name}' is paired with '${enumName}', but no migration declares a ` +
        `CHECK … IN (…) by that name. Rename the pairing, or drop it`,
    );
  }
}

if (failures > 0) {
  console.error(`\nenum check failed: ${failures} problem${failures === 1 ? '' : 's'}`);
  process.exit(1);
}

console.log(`enum check passed: ${constraints.size} constraints, ${Object.keys(PAIRED).length} paired`);
