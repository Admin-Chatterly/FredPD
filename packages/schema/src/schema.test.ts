import { execFile } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

import { describe, expect, it } from 'vitest';

import { ACCESS_POINTS, UNIT_STATUSES } from './enums';
import { ERROR_CODES, isErrorCode } from './errors';

const here = dirname(fileURLToPath(import.meta.url));
const GENERATED = resolve(here, '../../../resources/[fredpd]/fredpd/shared/generated/schema.lua');

describe('shared enumerations', () => {
  it.each([
    ['error codes', ERROR_CODES],
    ['access points', ACCESS_POINTS],
    ['unit statuses', UNIT_STATUSES],
  ])('%s are unique', (_name, values) => {
    expect(new Set(values).size).toBe(values.length);
  });

  it('narrows a known error code', () => {
    expect(isErrorCode('forbidden')).toBe(true);
    expect(isErrorCode('teapot')).toBe(false);
  });
});

describe('generated Lua', () => {
  /**
   * The committed Lua is generated from these definitions, so a stale copy
   * would let an enum mean one thing in the NUI and another in the route layer.
   * Regenerating and comparing is the only way to know it is current.
   */
  it('is in sync with the TypeScript definitions', async () => {
    const before = await readFile(GENERATED, 'utf8');

    await promisify(execFile)('node', ['--import', 'tsx', resolve(here, 'generate.ts')]);

    const after = await readFile(GENERATED, 'utf8');
    expect(after, 'run `pnpm schema:gen` and commit the result').toBe(before);
  });

  it('contains every value, spelled as Lua constants', async () => {
    const lua = await readFile(GENERATED, 'utf8');

    for (const code of ERROR_CODES) {
      expect(lua).toContain(`${code.toUpperCase()} = '${code}',`);
    }
  });
});
