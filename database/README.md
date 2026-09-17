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
- CI applies every migration to an empty database, and again on top of itself to
  prove idempotency, on each pull request (spec 15).

The migration runner and the `fpd_migrations` bookkeeping table land in M1
(spec 17.2). Until then, apply them by hand, in order:

```
for f in database/migrations/*.sql; do mysql -u root fredpd < "$f"; done
for f in database/seeds/*.sql;      do mysql -u root fredpd < "$f"; done
```

## Seeds

`seeds/` holds code tables that ship with the product rather than data a server
invents: permission groups now, the penal code and disposition codes later.
Seeds are idempotent — re-running one must not duplicate rows.

Note that the seeds create the permission **groups** but map no Discord roles to
them. Role ids are specific to your guild, so that mapping is made in game
(spec 7.30). A fresh install therefore grants nobody anything, which is the
correct default — and why the bootstrap below exists.

## Bootstrap

Three rows, once, to get from an empty database to something you can administer
from inside the game. Everything after this is configured in the MDT.

```sql
-- 1. Your agency.
INSERT INTO fpd_agencies (id, name, short_name)
VALUES ('lspd', 'Los Santos Police Department', 'LSPD');

-- 2. Yourself on the roster, by Discord id.
--    Find it in Discord: User Settings -> Advanced -> Developer Mode, then
--    right-click your name -> Copy User ID.
INSERT INTO fpd_officers (discord_id, agency_id, callsign, name)
VALUES ('<your discord id>', 'lspd', '12-40', 'A. Lindqvist');

-- 3. One Discord role mapped to the admin group. This is the only mapping you
--    ever have to write by hand; the rest are added from the MDT.
--    Right-click the role in Server Settings -> Roles -> Copy Role ID.
INSERT INTO fpd_role_map (discord_role_id, discord_role_name, group_key, agency_id)
VALUES ('<your discord role id>', 'FredPD Admin', 'admin', 'lspd');
```

Then restart the resource, open the MDT, and use **Administration → Discord
roles** to map the rest — and `/fredpd placement` to put the terminals, the lab
benches and the motor pool where they actually belong (spec 3.10).

Note that the `admin` group deliberately does **not** inherit `patrol`: being
able to configure FredPD is not the same as being cleared to read records
(spec 4.3, Appendix C). Map yourself a records group as well if you want both.

### Why is nothing happening yet?

- **The MDT opens but the rail is empty.** Your Discord roles are not mapped, or
  the gateway has not synced them into `fpd_discord_members` yet. Permissions
  come from Discord and only from Discord (invariant 2).
- **`/fredpd placement` says access denied.** The `admin` group grants
  `admin.placement.edit`; check step 3 above.
- **Nothing appears in the world.** Placements are created in game, not seeded.
  An empty `fpd_placements` is an install with no terminals yet, which is the
  expected starting state.
