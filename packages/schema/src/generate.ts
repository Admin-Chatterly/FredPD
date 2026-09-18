import { mkdir, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  ACCESS_POINTS,
  BROADCAST_KINDS,
  CALL_DISPOSITIONS,
  CALL_LINK_KINDS,
  CALL_LINK_ROLES,
  CALL_LOG_KINDS,
  CALL_PRIORITIES,
  CALL_PROGRESS_STATUSES,
  CALL_STATUSES,
  CALL_TYPES,
  CLASSIFICATIONS,
  HOTLIST_REASONS,
  INTEL_CASE_STATUSES,
  INTEL_CONFIDENCE,
  INTEL_ORG_STATUSES,
  INTEL_ORG_TYPES,
  INTEL_PERSON_STATUSES,
  INTEL_SOURCES,
  PLACEMENT_INTERACTIONS,
  PLACEMENT_KINDS,
  SELF_SET_UNIT_STATUSES,
  SUPERVISOR_UNIT_STATUSES,
  UNIT_STATUSES,
} from './enums';
import { ERROR_CODES } from './errors';
import { schemas, type FieldSpec, type Schema } from './schemas';

/**
 * Generates the Lua side of the shared schema (spec 17.2).
 *
 * TypeScript is the single source of truth; the Lua tables are produced from
 * it. That is the whole point: an enum or a field constraint can never mean one
 * thing in the NUI and another in the route layer, because only one of the two
 * is written by hand.
 *
 * CI regenerates and fails on any diff, so a stale file cannot merge.
 */

const here = dirname(fileURLToPath(import.meta.url));
const OUTPUT = resolve(here, '../../../resources/[fredpd]/fredpd/shared/generated/schema.lua');

const INDENT = '    ';

/** `en_route` becomes `EN_ROUTE`, the conventional Lua constant spelling. */
function constantName(value: string): string {
  return value.toUpperCase();
}

function luaString(value: string): string {
  return `'${value.replace(/\\/g, '\\\\').replace(/'/g, "\\'")}'`;
}

function luaList(values: readonly string[]): string {
  return `{ ${values.map(luaString).join(', ')} }`;
}

function enumTable(name: string, values: readonly string[], comment: string): string {
  const entries = values
    .map((value) => `${INDENT}${constantName(value)} = ${luaString(value)},`)
    .join('\n');

  return `--- ${comment}\nFredPD.${name} = {\n${entries}\n}\n`;
}

/**
 * The one enumeration whose members are numbers rather than strings.
 *
 * `CALL_PRIORITIES` is 1–4 because `fpd_calls.priority` is a `TINYINT
 * UNSIGNED` the pending queue is ordered by, so the values cannot be names.
 * The constants are `P1`–`P4`, which is what Appendix E calls them and what
 * the locale keys `cad.priority.p1`–`p4` are named after; the values stay
 * numbers, so `FredPD.CallPriority.P1` can be written straight into a
 * parameterized query.
 */
function numberTable(name: string, values: readonly number[], comment: string): string {
  const entries = values.map((value) => `${INDENT}P${value} = ${value},`).join('\n');

  return `--- ${comment}\nFredPD.${name} = {\n${entries}\n}\n`;
}

/** One field constraint, as a Lua table literal on a single line. */
function fieldTable(spec: FieldSpec): string {
  const parts = [`type = ${luaString(spec.type)}`];

  parts.push(`required = ${spec.required === true ? 'true' : 'false'}`);

  if ('min' in spec && spec.min !== undefined) parts.push(`min = ${spec.min}`);
  if ('max' in spec && spec.max !== undefined) parts.push(`max = ${spec.max}`);
  if (spec.type === 'enum') parts.push(`values = ${luaList(spec.values)}`);

  if (spec.type === 'string[]') {
    if (spec.maxItems !== undefined) parts.push(`maxItems = ${spec.maxItems}`);
    if (spec.maxLength !== undefined) parts.push(`maxLength = ${spec.maxLength}`);
  }

  return `{ ${parts.join(', ')} }`;
}

function schemaTable(name: string, schema: Schema): string {
  const fields = Object.entries(schema)
    .map(([field, spec]) => `${INDENT}${INDENT}${field} = ${fieldTable(spec)},`)
    .join('\n');

  return `${INDENT}${name} = {\n${fields}\n${INDENT}},`;
}

const banner = `--- GENERATED FILE -- DO NOT EDIT.
---
--- Written by \`pnpm schema:gen\` from packages/schema/src.
--- Change the TypeScript definitions and regenerate; CI fails on a stale copy.

FredPD = FredPD or {}
`;

const enums = [
  enumTable('ErrorCode', ERROR_CODES, 'Route error codes (spec 3.5).'),
  enumTable('AccessPoint', ACCESS_POINTS, 'Where a session opened FredPD from (spec 1.4).'),
  enumTable('UnitStatus', UNIT_STATUSES, 'Unit status (spec 7.1).'),
  enumTable('PlacementKind', PLACEMENT_KINDS, 'What a world placement opens (spec 3.10).'),
  enumTable(
    'PlacementInteraction',
    PLACEMENT_INTERACTIONS,
    'How a placement is reached in the world (spec 3.10).',
  ),
  enumTable('IntelPersonStatus', INTEL_PERSON_STATUSES, 'Person of interest status (spec 10).'),
  enumTable('IntelOrgType', INTEL_ORG_TYPES, 'Organisation type (spec 10).'),
  enumTable('IntelOrgStatus', INTEL_ORG_STATUSES, 'Organisation status (spec 10).'),
  enumTable('IntelSource', INTEL_SOURCES, 'Where a piece of intelligence came from (spec 10).'),
  enumTable('IntelConfidence', INTEL_CONFIDENCE, 'Confidence in a piece of intelligence (spec 10).'),
  enumTable('IntelCaseStatus', INTEL_CASE_STATUSES, 'Case status (spec 10).'),
  enumTable('Classification', CLASSIFICATIONS, 'Record classification levels (spec 4.5).'),

  // Dispatch (spec 7.16-7.18, M4). The CAD module is Lua, and every list
  // below is one the database also constrains or the log is written from, so
  // a hand-copied second spelling is how `enroute` reached a CHECK while the
  // code sent `en_route`. Generated, the two cannot disagree; changing one of
  // these enums and running `pnpm enum:check` is what catches the rest.
  enumTable(
    'SelfSetUnitStatus',
    SELF_SET_UNIT_STATUSES,
    "What an officer may set on their own unit (spec 7.16; Appendix F's ST).",
  ),
  enumTable(
    'SupervisorUnitStatus',
    SUPERVISOR_UNIT_STATUSES,
    'What a supervisor may set on somebody else (spec 7.16).',
  ),
  enumTable(
    'CallProgressStatus',
    CALL_PROGRESS_STATUSES,
    'The progress a unit reports on a call (spec 7.16).',
  ),
  numberTable('CallPriority', CALL_PRIORITIES, 'Call priority P1-P4 (Appendix E).'),
  enumTable('CallStatus', CALL_STATUSES, 'The call lifecycle (spec 7.16, Appendix E).'),
  enumTable('CallType', CALL_TYPES, 'What a call is (spec 7.16).'),
  enumTable('CallDisposition', CALL_DISPOSITIONS, 'How a call ended (spec 7.16).'),
  enumTable('CallLogKind', CALL_LOG_KINDS, 'What a line in the narrative log is (spec 7.16).'),
  enumTable('CallLinkKind', CALL_LINK_KINDS, 'What can be linked to a call (spec 7.16).'),
  enumTable('CallLinkRole', CALL_LINK_ROLES, 'How a person or vehicle is involved (spec 7.16).'),
  enumTable('BroadcastKind', BROADCAST_KINDS, 'What a dispatch broadcast is (spec 7.16).'),
  enumTable('HotlistReason', HOTLIST_REASONS, 'Why a plate is on the ALPR hotlist (spec 7.18).'),
].join('\n');

const schemaBody = Object.entries(schemas)
  .map(([name, schema]) => schemaTable(name, schema as Schema))
  .join('\n\n');

const schemaSection = `--- Route input schemas (spec 3.5). The route layer validates against these and
--- drops any key not listed, so a handler never sees a field it did not ask for.
FredPD.Schema = {
${schemaBody}
}
`;

await mkdir(dirname(OUTPUT), { recursive: true });
await writeFile(OUTPUT, `${banner}\n${enums}\n${schemaSection}`, 'utf8');

console.log(`schema: wrote ${OUTPUT}`);
