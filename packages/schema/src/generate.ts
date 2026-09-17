import { mkdir, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { ACCESS_POINTS, UNIT_STATUSES } from './enums';
import { ERROR_CODES } from './errors';

/**
 * Generates the Lua side of the shared schema (spec 17.2).
 *
 * TypeScript is the single source of truth; the Lua table is produced from it.
 * That is the whole point: an enum can never mean one thing in the NUI and
 * another in the route layer, because only one of the two is written by hand.
 *
 * CI regenerates and fails on any diff, so a stale file cannot merge.
 */

const here = dirname(fileURLToPath(import.meta.url));
const OUTPUT = resolve(here, '../../../resources/[fredpd]/fredpd/shared/generated/schema.lua');

/** `en_route` becomes `EN_ROUTE`, the conventional Lua constant spelling. */
function constantName(value: string): string {
  return value.toUpperCase();
}

function luaTable(name: string, values: readonly string[], comment: string): string {
  const entries = values
    .map((value) => `    ${constantName(value)} = '${value}',`)
    .join('\n');

  return `--- ${comment}\nFredPD.${name} = {\n${entries}\n}\n`;
}

const banner = `--- GENERATED FILE -- DO NOT EDIT.
---
--- Written by \`pnpm schema:gen\` from packages/schema/src.
--- Change the TypeScript definitions and regenerate; CI fails on a stale copy.

FredPD = FredPD or {}
`;

const body = [
  luaTable('ErrorCode', ERROR_CODES, 'Route error codes (spec 3.5).'),
  luaTable('AccessPoint', ACCESS_POINTS, 'Where a session opened FredPD from (spec 1.4).'),
  luaTable('UnitStatus', UNIT_STATUSES, 'Unit status (spec 7.1).'),
].join('\n');

await mkdir(dirname(OUTPUT), { recursive: true });
await writeFile(OUTPUT, `${banner}\n${body}`, 'utf8');

console.log(`schema: wrote ${OUTPUT}`);
