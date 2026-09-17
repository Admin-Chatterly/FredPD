# Database

MariaDB 11.4 LTS or newer, InnoDB, `utf8mb4_unicode_ci` — the same database the
ESX server already uses (spec 3.3).

## Migrations

`migrations/` is **append-only**. Invariant 8: a migration that has shipped is
never edited, not even to fix a typo in a comment. Correct it with a new
migration.

- Numbered `NNNN_short_name.sql`, applied in filename order.
- Every FredPD table is prefixed `fpd_` so it is obvious what belongs to this
  suite inside a shared ESX database.
- CI applies every migration to an empty database, and to a copy of the previous
  release's schema, on each pull request (spec 15).

The migration runner and the `fpd_migrations` bookkeeping table land in M1
(spec 17.2). Until then, apply a migration by hand:

```
mysql -u root fredpd < database/migrations/0001_migrations.sql
```

## Seeds

`seeds/` holds code tables that ship with the product rather than data a server
invents: the penal code, default permission groups, disposition codes. Seeds are
idempotent — re-running one must not duplicate rows.
