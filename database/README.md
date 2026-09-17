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

**There is no bootstrap SQL.** Fill in `discord` and `agency` in
`resources/[fredpd]/fredpd/config/server.lua`, start the resource, and run the
setup command it prints to the console (ADR-010):

```
/fredpd setup <code>        in the game chat, with the code from the console
fredpd_setup                or in the server console, while you are in game
```

That creates the agency, puts you on the roster using the Discord id FiveM
already knows you by, and maps every Discord role you hold to the `admin` group.
Everything after it is configured in the MDT.

Setup refuses once `fpd_officers` has any row, so there is exactly one first run.
The code exists so that on a public server the first player to guess the command
does not become an administrator: it is printed only to the server console.

`fpd_discord_members` is written by the role sync in `server/core/discord.lua`,
which refreshes the whole guild every few minutes and each player as they
connect. Nothing needs to touch that table by hand, and **nothing should ever
stamp `synced_at` on a schedule** — it is how FredPD knows whether to trust a
role list at all (spec 4.2).

Note that the `admin` group deliberately does **not** inherit `patrol`: being
able to configure FredPD is not the same as being cleared to read records
(spec 4.3, Appendix C). Map yourself a records group as well if you want both,
from **Administration → Discord roles** in the MDT.

### Why is nothing happening yet?

- **The console says the install is not set up.** Run the setup command it
  printed. It reprints on every resource start until it succeeds.
- **The MDT opens but the rail is empty.** No role of yours is mapped to a group.
  Permissions come from Discord and only from Discord (invariant 2).
- **"Discord could not be reached."** The token or guild id in
  `config/server.lua` is wrong, or the bot is missing the **Server Members**
  privileged intent.
- **"Your permissions are out of date."** The sync has not succeeded for over 15
  minutes. Check the console: it prints why each failure happened, without ever
  printing the token.
- **The motor pool is empty.** `fpd_fleet` has no rows for your agency, and its
  `label_key` column is a locale key rather than a name — see the Swedish
  installation guide, section 7.
- **Nothing appears in the world.** Placements are created in game with
  `/fredpd placement`, not seeded. An empty `fpd_placements` is an install with
  no terminals yet, which is the expected starting state.
