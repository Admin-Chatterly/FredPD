# ADR-012: Record numbers come from a locked counter row, not from MAX() of the target table

- **Status:** Accepted
- **Date:** 2026-09-17
- **Spec:** 13.1, Appendix D, 12.1; invariant 1

## Context

Spec 13.1 has said from the beginning that numbers are "generated from
`fpd_counters` inside a transaction with a row lock". `fpd_counters` was never
created — not in `0001_fredpd.sql`, not in `0002_evidence.sql` — so the evidence
module, the first module to need a record number, allocated the only other way
available: it read `MAX(sequence) + 1` inside the same statement that used it,
over the table it was inserting into.

```sql
INSERT INTO fpd_scenes (scene_number, ...)
SELECT CONCAT(?, LPAD(COALESCE(MAX(existing.sequence), 0) + 1, ?, '0')), ...
  FROM (SELECT CAST(SUBSTRING_INDEX(scene_number, '-', -1) AS UNSIGNED) AS sequence
          FROM fpd_scenes
         WHERE agency_id = ? AND scene_number LIKE ?) AS existing
```

One statement, so it reads as atomic. It is not, and the precise reason matters,
because the obvious reading is that InnoDB covers us here.

**Under REPEATABLE READ it mostly does.** Source and target are the same table,
so `INSERT ... SELECT` takes shared next-key locks over every row the subquery
scans. A second transaction scanning the same range blocks or deadlocks rather
than reading the same `MAX`. Mostly serialised — at the cost of locking every
row of the scan.

**Under READ COMMITTED it does not.** READ COMMITTED requires
`binlog_format = ROW` (the MariaDB default since 10.2), and with it InnoDB takes
no gap locks and releases non-matching row locks as it goes. The scanning half
of the `INSERT ... SELECT` is then an ordinary consistent read. Two officers
opening a scene in the same tick read the same `MAX`, compute the same sequence,
and `uq_fpd_scenes_number` refuses one of the two transactions outright — in
front of an officer standing over a body.

READ COMMITTED is not hypothetical. It is the default on several managed MariaDB
products, it is standard advice for reducing lock contention on a busy ESX
`users` table, and many servers set it. **FredPD cannot detect its way out of
this**: the isolation level is a server variable the operator owns, and refusing
to boot under READ COMMITTED would be refusing to run on a large share of the
servers this is written for.

A second, smaller defect came with it: `scene_number LIKE 'LSPD-S-2026-%'` has no
index to use, so every allocation scanned a growing fraction of the table. This
was the one write path that got measurably slower every day the server ran, and
section 12's budgets are acceptance criteria.

## Decision

**Allocate from a counter row held under an exclusive lock, inside the
transaction that writes the record.** `0005_records.sql` creates `fpd_counters`
`(agency_id, kind, year, next_value)` with that composite primary key, and
`server/core/counters.lua` is the only code that reads or writes it.

An allocation is four statements in one transaction:

1. `INSERT INTO fpd_counters ... ON DUPLICATE KEY UPDATE next_value = next_value`
   — creates the row for this `(agency, kind, year)`, or takes an **exclusive**
   lock on the existing one.
2. `SELECT next_value ... FOR UPDATE` — the lock spec 13.1 names.
3. The caller's `INSERT`, which reads the locked counter through a scalar
   subquery.
4. `UPDATE ... SET next_value = next_value + 1`.

Two details are deliberate:

- **Not `INSERT IGNORE` in step 1.** On a duplicate, `INSERT IGNORE` takes a
  *shared* lock on the existing row. Step 2 would then have to upgrade it, and
  two transactions each holding S and each waiting for X is a deadlock.
  `ON DUPLICATE KEY UPDATE` takes the exclusive lock immediately.
- **Step 2 stays even though step 1 already holds the lock.** It costs one
  primary-key lookup, it is the statement the spec names, and it means the
  correctness of every record number in the suite does not rest on a reader
  knowing MariaDB's duplicate-key locking by heart.

This behaves identically under READ UNCOMMITTED, READ COMMITTED, REPEATABLE READ
and SERIALIZABLE, which is the property being bought.

`year = 0` means a sequence that is not year-scoped: a master person number is
`P-{######}` with no year in it (Appendix D).

## Consequences

- `evidence/repo.lua` changes at both of its allocation sites — `createScene`
  and `insertEvidence` — and every number introduced afterwards (person, report,
  case, warrant, BOLO) uses the same helper. There is now one place where a
  sequence is taken.
- `createScene` becomes a transaction and therefore reads its new id back
  afterwards, scoped to the officer who wrote it, the way `createLabRequest`
  already did. A transaction reports only whether it committed.
- Allocation cost stops depending on table size: one primary-key lookup instead
  of an unindexed `LIKE` scan.
- Contention moves from "every row of the scan" to "one row per agency, kind and
  year", held for the length of one insert. A transaction must allocate **one**
  number; two counters locked in one transaction, in an order two call sites
  disagree about, is how a deadlock gets invented later.
- A rolled-back transaction does not consume a number, because the bump rolls
  back with it. A number is therefore not proof that a record exists, which was
  already true and is now true for a simpler reason.
- `0005_records.sql` backfills the evidence and scene counters from the highest
  number already issued, parsed out of the number itself rather than taken from
  a timestamp. Without that, a server with existing evidence would restart at 1
  and hit the unique index on every insert — the same officer-facing failure,
  made worse.

## Alternatives considered

**Leave it, and set REPEATABLE READ in the installation guide.** Rejected. It is
advice, not a control; it can be changed by a hosting provider without anybody
noticing; and it makes a correctness property of FredPD depend on a variable
FredPD does not own.

**`SELECT ... FOR UPDATE` on the target table's own MAX.** Locks a range of the
records table rather than one counter row, gets slower as the table grows, and
under READ COMMITTED still has nothing to lock when the range is empty — which
is precisely the first record of each year.

**Catch the duplicate-key error and retry.** Works, and is what a retry loop
around the old statement would have done. Rejected because the collision rate
rises with concurrency exactly when the server is busiest, each retry is another
full scan, and the failure mode of a retry budget being exhausted is the error
the officer was going to see anyway.

**`AUTO_INCREMENT` and format the number on read.** Loses the per-agency,
per-year sequence that Appendix D's formats are built on, and makes a number
change if the formatting ever changes — a number is quoted in reports and read
aloud on the radio, so it has to be stored.
