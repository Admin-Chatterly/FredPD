# ADR-024: The master SQL corrects what MariaDB cannot run

- **Status:** Accepted
- **Date:** 2026-09-24
- **Spec:** 3.3; invariant 8
- **Relates to:** `database/combined/fredpd_all.sql`, `tools/combine-sql.ts`

## Context

An operator installing FredPD runs one file, `database/combined/fredpd_all.sql`
(`docs/installation.sv.md`, step 2). The file contains every migration and seed
in order. It was assembled by a script that lived outside the repository, so
nothing checked that it was current, and nothing ever ran it against MariaDB.

When an operator ran it, HeidiSQL stopped at migration `0026`:

```
SQL-fel (1064): … near 'FOREIGN KEY (`loadout_id`) REFERENCES `fpd_personnel_loadout` (`id`)…'
```

Applying every migration to MariaDB found four migrations that cannot run:

| Migration | Statement | MariaDB |
| --- | --- | --- |
| `0026_personnel_loadout` | `ADD CONSTRAINT IF NOT EXISTS fk_… FOREIGN KEY (…)` | 1064: `IF NOT EXISTS` after `ADD CONSTRAINT` is valid only for `CHECK`; a foreign key takes it after `FOREIGN KEY` |
| `0033_atal_defendant` | the same | 1064 |
| `0037_impound_lot` | the same, together with a valid `CHECK`, which therefore never ran either | 1064 |
| `0035_field_interviews` | `ck_fpd_fi_cards_subject` reads `person_id` and `vehicle_id` | 1901: a `CHECK` may not read a column that an `ON DELETE SET NULL` key changes; `fpd_fi_cards` and `fpd_fi_associates` were never created |

CI's database job applied the migrations one by one to MariaDB 11.4. It had
therefore been failing since `0026`.

Invariant 8 says a migration that has shipped is never edited. The obvious fix
was to edit the four statements in place. That was refused as a change to
shipped migrations.

## Decision

**The master SQL is generated in the repository and corrects these statements
as it is combined. The migrations stay exactly as they shipped.**

- `tools/combine-sql.ts` writes the file (`pnpm sql:combine`). It keeps the
  file's format: the Swedish header, one `====` block per source file, and
  seeds prefixed `seed: `.
- Its `CORRECTIONS` list holds each fix: the text as shipped, the replacement,
  and one line explaining why. That line is written into the file above the
  corrected statement, marked `[combine-sql]`. Each correction must match its
  source exactly once, otherwise the tool fails. A stale correction therefore
  cannot silently stop correcting anything.
- `pnpm sql:check` is part of `pnpm check` and CI. It fails when the file is not
  what the tool would write, so a new migration or seed cannot ship without the
  master file. The date on the first line is the only thing it ignores.
- CI's database job applies the master file to MariaDB 11.4 twice. Applying the
  raw migrations one by one is no longer supported, because four of them fail.

## Why this does not weaken invariant 8

The invariant exists so that every install that applied a migration has the
same schema. A statement that no MariaDB can run was never applied anywhere, so
correcting it changes no schema that exists.

Three kinds of database were tested on MariaDB, and all ended with identical
tables, columns and constraints (104 tables):

1. a fresh database;
2. one left half-applied by the old master file, stopped at `0026`;
3. one where the old file was run with errors ignored.

The corrected file also runs a second time with no errors.

Meanwhile the migration files, their hashes and the history in them are
untouched.

## Consequences

- The master file is the one supported way to install and upgrade. The
  installation guide and `database/README.md` say so. A migration that MariaDB
  cannot run is fixed in `CORRECTIONS`, never in the migration.
- A new migration still has to be valid MariaDB. CI now catches one that is
  not, on the branch that adds it.
- The removed `ck_fpd_fi_cards_subject` is enforced where cards are written
  (`Interviews.hasSubject`), which was already the case.
