import { mkdir, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  ACCESS_POINTS,
  CLASSIFICATIONS,
  INTEL_CASE_STATUSES,
  INTEL_CONFIDENCE,
  INTEL_ORG_STATUSES,
  INTEL_ORG_TYPES,
  INTEL_PERSON_STATUSES,
  INTEL_SOURCES,
  PLACEMENT_INTERACTIONS,
  PLACEMENT_KINDS,
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
