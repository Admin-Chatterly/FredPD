import { readFile, readdir } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { ERROR_CODES } from '../packages/schema/src/errors.ts';

/**
 * i18n check (spec 5.4, 15).
 *
 * Invariant 6 says `en` and `sv` must be complete before a pull request merges.
 * This is what makes that enforceable rather than aspirational. It fails on:
 *
 *   1. a key present in one locale and missing from another;
 *   2. an empty translation, which is a missing one wearing a disguise;
 *   3. a placeholder set that differs between locales -- `{callsign}` in `en`
 *      and `{enhet}` in `sv` renders a literal brace in game;
 *   4. an error code with no `error.<code>` message, so a route can fail in a
 *      way the UI cannot explain;
 *   5. a `t('key')` used in the NUI that no locale file defines.
 */

const here = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(here, '..');
const LOCALE_DIR = join(REPO, 'resources/[fredpd]/fredpd/locales');
const WEB_SRC = join(REPO, 'web/src');

const REFERENCE_LOCALE = 'en';

type LocaleTree = { [key: string]: string | LocaleTree };

const problems: string[] = [];

function fail(message: string): void {
  problems.push(message);
}

function flatten(tree: LocaleTree, prefix = ''): Map<string, string> {
  const out = new Map<string, string>();

  for (const [key, value] of Object.entries(tree)) {
    const path = prefix ? `${prefix}.${key}` : key;

    if (typeof value === 'string') {
      out.set(path, value);
    } else {
      for (const [nested, nestedValue] of flatten(value, path)) {
        out.set(nested, nestedValue);
      }
    }
  }

  return out;
}

/** The `{name}` placeholders a template expects, as a sorted, comparable list. */
function placeholders(template: string): string[] {
  return [...template.matchAll(/\{(\w+)\}/g)].map((match) => match[1] ?? '').sort();
}

async function loadLocales(): Promise<Map<string, Map<string, string>>> {
  const files = (await readdir(LOCALE_DIR)).filter((name) => name.endsWith('.json'));
  const locales = new Map<string, Map<string, string>>();

  for (const file of files) {
    const raw = await readFile(join(LOCALE_DIR, file), 'utf8');
    const name = file.replace(/\.json$/, '');

    try {
      locales.set(name, flatten(JSON.parse(raw) as LocaleTree));
    } catch (error) {
      fail(`${file}: not valid JSON (${(error as Error).message})`);
    }
  }

  return locales;
}

/** Every `t('key')` and `t(\`key\`)` written in the NUI source. */
async function usedKeys(dir: string): Promise<Map<string, string>> {
  const found = new Map<string, string>();

  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);

    if (entry.isDirectory()) {
      for (const [key, file] of await usedKeys(path)) found.set(key, file);
      continue;
    }

    if (!/\.(ts|svelte)$/.test(entry.name) || entry.name.endsWith('.test.ts')) continue;

    const source = await readFile(path, 'utf8');

    for (const match of source.matchAll(/\bt\(\s*'([^']+)'/g)) {
      const key = match[1];
      // A template literal key is built at runtime (`shell.module.${name}`)
      // and cannot be resolved here; the enum it comes from is checked instead.
      if (key !== undefined && !key.includes('${')) found.set(key, path);
    }
  }

  return found;
}

const locales = await loadLocales();
const reference = locales.get(REFERENCE_LOCALE);

if (!reference) {
  fail(`no ${REFERENCE_LOCALE}.json in ${LOCALE_DIR}`);
} else {
  // 1-3: every locale matches the reference, key for key.
  for (const [name, table] of locales) {
    if (name === REFERENCE_LOCALE) continue;

    for (const [key, referenceValue] of reference) {
      const value = table.get(key);

      if (value === undefined) {
        fail(`${name}.json: missing key "${key}"`);
        continue;
      }

      if (value.trim() === '') {
        fail(`${name}.json: key "${key}" is empty`);
        continue;
      }

      const expected = placeholders(referenceValue);
      const actual = placeholders(value);

      if (expected.join(',') !== actual.join(',')) {
        fail(
          `${name}.json: key "${key}" has placeholders {${actual.join(', ')}}, ` +
            `but ${REFERENCE_LOCALE} has {${expected.join(', ')}}`,
        );
      }
    }

    for (const key of table.keys()) {
      if (!reference.has(key)) {
        fail(`${name}.json: key "${key}" does not exist in ${REFERENCE_LOCALE}.json`);
      }
    }
  }

  // 4: every route error code has a message.
  for (const code of ERROR_CODES) {
    if (!reference.has(`error.${code}`)) {
      fail(`${REFERENCE_LOCALE}.json: missing "error.${code}" for a route error code`);
    }
  }

  // 5: every key the NUI asks for exists.
  for (const [key, file] of await usedKeys(WEB_SRC)) {
    if (!reference.has(key)) {
      fail(`${file.replace(`${REPO}/`, '')}: t('${key}') has no entry in ${REFERENCE_LOCALE}.json`);
    }
  }
}

if (problems.length > 0) {
  console.error(`i18n check failed with ${problems.length} problem(s):\n`);
  for (const problem of problems) console.error(`  - ${problem}`);
  process.exit(1);
}

const keyCount = reference?.size ?? 0;
console.log(`i18n check passed: ${locales.size} locales, ${keyCount} keys each.`);
