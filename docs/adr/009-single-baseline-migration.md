# ADR-009: The schema ships as one baseline migration

- **Status:** Accepted
- **Date:** 2026-09-17
- **Spec:** 0 (invariant 8), 3.3, 13.1, 17.2

## Context

The schema was written in three files as it was built: `0001_migrations.sql`
(bookkeeping), `0002_core.sql` (the M1 platform) and `0003_intel.sql` (the
intelligence register ported from PD-Span). That split recorded the order the
work happened in, which is useful while building and meaningless to somebody
installing the result.

Invariant 8 says migrations are append-only and a shipped migration is never
edited. The question is what "shipped" means for a suite that has never been
installed anywhere. These three files had been applied in exactly one place: the
CI job, against a MariaDB container created and destroyed inside the run. No
server has ever held a FredPD table.

## Decision

Consolidate the three into one baseline, `0001_fredpd.sql`, containing all 23
tables in foreign-key order, and the two seeds into `0001_permissions.sql`.

Invariant 8 applies from this commit forward. The next schema change is
`0002_*.sql` and this file is frozen.

The consolidation was done now, deliberately, before the first release. The
rule exists to protect data that already exists; where no such data exists
anywhere, rewriting the baseline costs nothing and leaves a server with one
file to apply instead of three whose boundaries describe our build order rather
than anything about their database. After the first server applies it, the same
edit would be precisely what the invariant forbids — there would be no way to
tell which of two schemas a given database actually had.

Idempotency is what makes this safe to state rather than hope: every statement
is `CREATE TABLE IF NOT EXISTS`, and CI applies the file to an empty database
and then again on top of itself on every push.

## Consequences

- A fresh install is two commands: one migration, one seed.
- The history of how the schema was assembled is in git, not in filenames. That
  is where it belongs.
- `fpd_migrations` will record one row for the baseline rather than three. Since
  the runner (M1, spec 17.2) has never recorded anything on a live server,
  there is nothing to reconcile.
- The three-file split cannot be recovered from a database, only from git. This
  is the last moment that is free; it is the reason the decision is written
  down rather than just made.
- Seeds were consolidated for the same reason, but they were never protected by
  invariant 8 in the first place: a seed is an idempotent upsert of code tables
  and may be reorganised at any time.
