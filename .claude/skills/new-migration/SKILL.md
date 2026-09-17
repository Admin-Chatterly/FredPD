---
name: new-migration
description: Add a database migration to FredPD. Use whenever a table, column, index or code table changes.
---

# Adding a migration

`database/migrations/` is **append-only** (invariant 8). A migration that has
shipped is never edited — not to add a column, not to fix a typo, not even in a
comment. Correct it with a new migration. A hook blocks edits to existing files
here; if it fires, you are doing the wrong thing.

## 1. Create the file

`database/migrations/NNNN_short_name.sql`, numbered one above the highest that
exists. Lower-case, underscores, describing the change: `0007_add_bolo_expiry.sql`.

`0001_fredpd.sql` is the released baseline — the whole schema as first shipped
(ADR-009). It is frozen. Every change since is its own file.

## 2. Write it

- Every FredPD table is prefixed `fpd_`.
- `ENGINE = InnoDB`, `DEFAULT CHARSET = utf8mb4`, `COLLATE = utf8mb4_unicode_ci`.
- Make it **idempotent**: `CREATE TABLE IF NOT EXISTS`, and guard an
  `ALTER TABLE` so re-running is harmless. CI applies every migration twice.
- Index what will actually be filtered and sorted. A record table that grows for
  a year needs the index before it grows, not after (spec 12).
- Foreign keys where the relationship is real, with the delete behavior stated
  deliberately: cascade, restrict or set null — each says something different
  about whether intelligence survives a deletion.
- Comment *why*, not what. The column name already says what.

## 3. Consider the data that exists

If the change alters the meaning of existing rows, the migration backfills them.
A column added `NOT NULL` without a default breaks a live server on upgrade.

## 4. Seeds are separate

Code tables that ship with the product — penal code, permission groups,
disposition codes — belong in `database/seeds/`, and must be re-runnable
without duplicating rows.

## 5. Types

If the change affects an entity the NUI or gateway reads, update
`packages/schema/src/` and run `pnpm schema:gen`.

## Before you finish

Apply it to an empty database, then apply it **again** to prove idempotency —
that is exactly what CI does.
