# Database

MariaDB 11.4 LTS or newer, InnoDB, `utf8mb4_unicode_ci` — the same database the
ESX server already uses (spec 3.3).

## Migrations

`0001_fredpd.sql` is the entire schema as first released — all 23 tables, in
foreign-key order. A fresh install is one file.

`migrations/` is **append-only**. Invariant 8: a migration that has shipped is
never edited, not even to fix a typo in a comment. Correct it with a new
migration. `0001` was consolidated from three files before the first release,
while the only place it had ever run was CI against a throwaway database; that
is the one moment such a rewrite is safe, and it has passed (ADR-009).

- Numbered `NNNN_short_name.sql`, applied in filename order.
- Every statement is `CREATE TABLE IF NOT EXISTS`, so re-applying a migration
  is a no-op rather than an error.
- Every FredPD table is prefixed `fpd_` so it is obvious what belongs to this
  suite inside a shared ESX database.
- CI applies every migration to an empty MariaDB 11.4, and again on top of
  itself to prove idempotency, on each push (spec 15).

The migration runner and the `fpd_migrations` bookkeeping table land in M1
(spec 17.2). Until then, apply them by hand:

```
mysql -u root fredpd < database/migrations/0001_fredpd.sql
mysql -u root fredpd < database/seeds/0001_permissions.sql
```

Once later versions add migrations, run the whole directory in filename order
instead — applying one twice does nothing:

```
for f in database/migrations/*.sql; do mysql -u root fredpd < "$f"; done
for f in database/seeds/*.sql;      do mysql -u root fredpd < "$f"; done
```

## Seeds

`seeds/` holds code tables that ship with the product rather than data a server
invents: the permission groups now — platform and intelligence alike, in
`0001_permissions.sql` — and the penal code and disposition codes later.
Seeds are idempotent — re-running one must not duplicate rows.

Note that the seeds create the permission **groups** but map no Discord roles to
them. Role ids are specific to your guild, so that mapping is made in game
(spec 7.30). A fresh install therefore grants nobody anything, which is the
correct default — and why the bootstrap below exists.

## Bootstrap

Four rows, once, to get from an empty database to something you can administer
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

-- 3. Your Discord roles.
--    This row is normally written by the gateway's bot -- which is not built
--    yet (M1). Until it is, insert it by hand: without it you hold no roles,
--    and therefore no permissions at all.
--    Right-click the role in Server Settings -> Roles -> Copy Role ID.
INSERT INTO fpd_discord_members (discord_id, roles, synced_at)
VALUES ('<your discord id>', '["<your discord role id>"]', NOW());

-- 4. That role mapped to the admin group. This is the only mapping you ever
--    have to write by hand; the rest are added from the MDT.
INSERT INTO fpd_role_map (discord_role_id, discord_role_name, group_key, agency_id)
VALUES ('<your discord role id>', 'FredPD Admin', 'admin', 'lspd');
```

`roles` is a JSON array — several roles are `'["111…","222…"]'`.

**While the bot is missing,** `synced_at` decides how fresh FredPD considers your
role list. Older than 15 minutes and sensitive actions are refused; older than 6
hours and the session goes read-only. Run
`UPDATE fpd_discord_members SET synced_at = NOW();` before administering.

Then restart the resource, open the MDT, and use **Administration → Discord
roles** to map the rest — and `/fredpd placement` to put the terminals, the lab
benches and the motor pool where they actually belong (spec 3.10).

Note that the `admin` group deliberately does **not** inherit `patrol`: being
able to configure FredPD is not the same as being cleared to read records
(spec 4.3, Appendix C). Map yourself a records group as well if you want both.

### Why is nothing happening yet?

- **The MDT opens but the rail is empty.** Either no role is mapped, or there is
  no row for you in `fpd_discord_members` (step 3 above). Permissions come from
  Discord and only from Discord (invariant 2).
- **"Your permissions are out of date."** `synced_at` is over 15 minutes old.
- **The motor pool is empty.** `fpd_fleet` has no rows for your agency, and its
  `label_key` column is a locale key rather than a name — see the Swedish
  installation guide, section 7.
- **`/fredpd placement` says access denied.** The `admin` group grants
  `admin.placement.edit`; check step 4 above.
- **Nothing appears in the world.** Placements are created in game, not seeded.
  An empty `fpd_placements` is an install with no terminals yet, which is the
  expected starting state.
