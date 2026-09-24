import { readdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

/**
 * Builds `database/combined/fredpd_all.sql`: every migration and every seed in
 * one file, in the order they apply, for an operator who runs one script in
 * HeidiSQL rather than forty-odd (docs/installation.sv.md, step 2).
 *
 *   pnpm sql:combine   writes the file
 *   pnpm sql:check     fails when the file is not what this would write
 *
 * The check is part of `pnpm check`, so a migration or seed added without
 * regenerating fails the build rather than reaching an operator as a master
 * file that is silently missing it. The date on the first line is the only
 * thing the check ignores.
 *
 * ## Corrections (ADR-024)
 *
 * Four migrations shipped with a statement MariaDB cannot run. Invariant 8
 * says a shipped migration is never edited, so they are corrected *here*, as
 * the file is put together, and nowhere else. `CORRECTIONS` lists each one:
 * the exact text as shipped, what it becomes, and why. Each must match its
 * source exactly once, or this fails -- a correction that no longer matches
 * is one that no longer corrects anything, and the next operator would meet
 * the MariaDB error again with nothing to say why.
 *
 * A failing statement never ran on any install, so correcting it changes no
 * schema that exists anywhere. Every other byte of every source is copied as
 * it is.
 *
 * CI's database job applies the file this writes to MariaDB 11.4, twice, and
 * fails on any error: the file's promise is that it runs, and runs again.
 */

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const database = join(root, 'database');
const target = join(database, 'combined', 'fredpd_all.sql');

interface Correction {
  /** Source path under `database/`. */
  file: string;
  /** The text as shipped, matched exactly once. */
  find: string;
  replace: string;
  /** One line, Swedish like the rest of the file's own comments, written above the correction. */
  why: string;
}

const MARK = '-- [combine-sql] Rättat vid sammanslagningen (ADR-024):';

/** `ADD CONSTRAINT IF NOT EXISTS name FOREIGN KEY (…)` → `ADD CONSTRAINT name FOREIGN KEY IF NOT EXISTS (…)`. */
function foreignKey(file: string, name: string, column: string): Correction {
  return {
    file,
    find: `    ADD CONSTRAINT IF NOT EXISTS \`${name}\` FOREIGN KEY (\`${column}\`)\n`,
    replace: `    ADD CONSTRAINT \`${name}\` FOREIGN KEY IF NOT EXISTS (\`${column}\`)\n`,
    why:
      'MariaDB läser IF NOT EXISTS efter FOREIGN KEY; efter ADD CONSTRAINT gäller det bara CHECK (fel 1064).',
  };
}

const CORRECTIONS: Correction[] = [
  foreignKey('migrations/0026_personnel_loadout.sql', 'fk_fpd_officers_loadout', 'loadout_id'),
  foreignKey('migrations/0033_atal_defendant.sql', 'fk_fpd_atal_person', 'person_id'),
  foreignKey('migrations/0037_impound_lot.sql', 'fk_fpd_impound_lot', 'lot_id'),
  {
    file: 'migrations/0035_field_interviews.sql',
    find: [
      "        ('open', 'internal', 'restricted', 'confidential', 'secret')),",
      '    -- A card about nobody and nothing is not a card.',
      '    CONSTRAINT `ck_fpd_fi_cards_subject` CHECK (`person_id` IS NOT NULL OR `vehicle_id` IS NOT NULL',
      '        OR `narrative` IS NOT NULL)',
      '',
    ].join('\n'),
    replace: [
      "        ('open', 'internal', 'restricted', 'confidential', 'secret'))",
      '    -- A card about nobody and nothing is not a card: `Interviews.hasSubject`',
      '    -- refuses one when it is written.',
      '',
    ].join('\n'),
    why:
      'ck_fpd_fi_cards_subject borttagen: en CHECK får inte läsa kolumner som en ON DELETE SET NULL-nyckel ändrar (fel 1901).',
  },
];

/**
 * The header, word for word the format the file has always had, plus one
 * line naming the corrections.
 */
function header(date: string): string {
  return [
    `-- FredPD — alla migrationer och seeds i en fil, sammanfogade ${date}.`,
    '-- Genererad av tools/combine-sql, INTE en egen migration -- redigera aldrig den här filen,',
    '-- redigera källfilerna i database/migrations/ och database/seeds/ och slå ihop på nytt.',
    '-- Körs mot samma schema som ESX. Säker att köra om (migrationerna har IF NOT EXISTS,',
    '-- seeds är upsert/INSERT IGNORE).',
    '-- Satser som MariaDB inte kan köra är rättade här, inte i källfilerna: sök på [combine-sql].',
    '',
    '',
  ].join('\n');
}

const RULE = '-- ============================================================';

async function sources(dir: 'migrations' | 'seeds'): Promise<string[]> {
  return (await readdir(join(database, dir))).filter((name) => name.endsWith('.sql')).sort();
}

function applyCorrections(file: string, text: string): string {
  let out = text;
  for (const correction of CORRECTIONS.filter((entry) => entry.file === file)) {
    const count = out.split(correction.find).length - 1;
    if (count !== 1) {
      throw new Error(
        `combine-sql: the correction for ${file} matches ${count} times, not once. ` +
          'Its source changed or the correction is stale; see CORRECTIONS in tools/combine-sql.ts.',
      );
    }
    out = out.replace(correction.find, `${MARK} ${correction.why}\n${correction.replace}`);
  }
  return out;
}

async function build(date: string): Promise<string> {
  const known = new Set(CORRECTIONS.map((entry) => entry.file));
  let out = header(date);

  for (const [dir, prefix] of [
    ['migrations', ''],
    ['seeds', 'seed: '],
  ] as const) {
    for (const name of await sources(dir)) {
      const file = `${dir}/${name}`;
      known.delete(file);
      let text = applyCorrections(file, await readFile(join(database, file), 'utf8'));
      if (!text.endsWith('\n')) text += '\n';
      out += `${RULE}\n-- ${prefix}${name}\n${RULE}\n${text}\n`;
    }
  }

  if (known.size > 0) {
    throw new Error(`combine-sql: corrections name files that do not exist: ${[...known].join(', ')}`);
  }

  return `${out.replace(/\n+$/, '')}\n`;
}

/** Everything but the first line, which carries the date. */
function body(text: string): string {
  return text.slice(text.indexOf('\n') + 1);
}

async function main(): Promise<void> {
  const write = process.argv.includes('--write');
  const today = new Date().toISOString().slice(0, 10);
  const next = await build(today);
  const shown = relative(root, target);

  if (write) {
    await writeFile(target, next, 'utf8');
    console.log(`combine-sql: wrote ${shown}`);
    return;
  }

  let current = '';
  try {
    current = await readFile(target, 'utf8');
  } catch {
    // Missing counts as stale.
  }

  if (body(current) !== body(next)) {
    console.error(`combine-sql: ${shown} is stale. Run \`pnpm sql:combine\` and commit the result.`);
    process.exit(1);
  }

  console.log(`combine-sql: ${shown} is current (${CORRECTIONS.length} corrections applied).`);
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
