# FredPD

Police records, dispatch, evidence and forensics suite for an ESX FiveM server.

FredPD is the in-game computer system of a police agency, built to feel like the
software officers, dispatchers, detectives, forensic staff and prosecutors
actually use: fast, dense, keyboard-driven and procedural. Realism comes from
real workflows — approvals, chain of custody, lab turnaround, warrant review,
hit confirmation — not from visual effects. Everything a player can see is
decided by their Discord roles.

**[`docs/FredPD.md`](docs/FredPD.md) is the specification and the single source
of truth.** Section 0 lists the invariants that override everything else.

Two guides in Swedish, for the people who run and use the server:

- **[`docs/installation.sv.md`](docs/installation.sv.md)** — installation and
  deployment: dependencies, build, database, convars, bootstrap, troubleshooting.
- **[`docs/handbok.sv.md`](docs/handbok.sv.md)** — the service manual officers
  read: terminals, the internal channel, the motor pool, and what gets logged.

## Status

**M0 complete, M1 in progress.** The monorepo, toolchain, CI and the mock NUI
bridge are in place, and the platform core is building out: the route layer,
sessions, the Discord-derived permission model, the audit log, and the first
modules.

Working today:

- **Setup is one config file and one command.** A Discord bot token, a guild id
  and an agency name, then `/fredpd setup` in game (ADR-010).
- **Discord roles sync themselves.** FXServer reads the guild's member list
  directly, so a role added or removed takes effect without a restart and
  without anything to deploy beside the server.
- **Permissions configured in game.** Map a Discord role to a permission group
  from the MDT; it takes effect immediately, with no restart (spec 4.3, 7.30).
- **World positions configured in game.** `/fredpd placement` puts a terminal,
  a lab bench or a motor pool ped where it actually belongs — aim at a prop to
  bind it, or place a ped — instead of editing coordinates in a config file
  (spec 3.10, ADR-006).
- **Internal police channel** in the standard game chat: `/pd <message>`,
  delivered only to officers who may read it (spec 7.26, ADR-007).
- **Agency motor pool** with an attendant ped, permission-gated vehicles and a
  log of every draw and return (spec 7.31).
- **The intelligence register** — people, organizations, the intel log, vehicles,
  cases and the links between them — ported from PD-Span onto the server's own
  MariaDB, so it persists in the game database (spec 10).

Records, dispatch, evidence, lab and court follow in M2–M6; see the roadmap in
spec section 17.

## Layout

```
resources/[fredpd]/
  fredpd/               core: sessions, permissions, records, dispatch, NUI host
  fredpd_forensics/     evidence generation and scene tools      (M3)
  fredpd_surveillance/  interception, warrant-gated              (M5)
  fredpd_assets/        streamed props and sounds
web/                    Svelte 5 NUI, builds into fredpd/web/dist
gateway/                Node.js service: Discord sync, media, PDF, scheduler
packages/schema/        route and entity schemas → TS types and generated Lua
database/               append-only migrations, and seeds
tools/                  i18n checker
vendor/pd-span/         the existing intelligence board, for integration (§10)
docs/adr/               architecture decision records
```

## Getting started

Requires Node 24 (see `.nvmrc`) and pnpm.

```bash
pnpm install
pnpm dev:web      # the NUI in a browser, against fixtures — no game server needed
```

`pnpm dev:web` is the fastest way to see what this is. The NUI talks to a mock
bridge backed by fixtures, so the whole interface runs in a plain browser.
Try `?locale=sv`, `?latency=400` and `?fail=forbidden`.

### Commands

| Command | What it does |
| --- | --- |
| `pnpm build` | Schema codegen → NUI → gateway |
| `pnpm check` | ESLint, TypeScript, svelte-check, i18n |
| `pnpm test` | Unit tests (Vitest) |
| `pnpm test:lua` | Lua unit tests (busted) |
| `pnpm lint:lua` | luacheck over the resources |
| `pnpm test:e2e` | NUI tests in a browser (Playwright) |
| `pnpm schema:gen` | Regenerate the Lua schema — commit the result |
| `pnpm i18n:check` | `en` and `sv` complete and consistent |

### Running it on a server

This needs an FXServer with ESX (`es_extended`), ox_lib and oxmysql, and a
MariaDB database. `p_policejob`, `esx_society`, `esx_textui` and
`esx_menu_dialog` are used where present and degrade with a warning where not —
each sits behind a bridge (spec 3.8, ADR-008).

Four steps, and no convars:

1. **Copy** `resources/[fredpd]/` to the server. Use the release bundle, or run
   `pnpm build` first — the NUI is served from
   `resources/[fredpd]/fredpd/web/dist`, which the build produces.
2. **Apply** every file in `database/migrations/` in filename order, then
   `database/seeds/0001_permissions.sql`. In one line:

   ```
   for f in database/migrations/*.sql; do mysql -u root YOUR_ESX_SCHEMA < "$f"; done
   ```

   Applying only the first is the mistake this used to invite: the server
   starts, says the schema is present, and then fails on the first evidence
   call. It now refuses to start instead, naming the tables it cannot find.
3. **Edit** `resources/[fredpd]/fredpd/config/server.lua` — a Discord bot token,
   your guild id, and your agency's name. That is the only file to edit, and the
   only configuration there is.
4. **Run the setup command** the console prints on first start. In the console,
   `fredpd_setup <player id>` lists your Discord roles; `fredpd_setup <player
   id> <role id>` then creates the agency, puts you on the roster, and makes
   that one role grant administration. `/fredpd setup <code> <role id>` does the
   same from the game chat.

Everything after that is configured from inside the game: Discord roles from
**Administration** in the MDT, and world positions with `/fredpd placement`.

The bot needs the **Server Members** privileged intent — reading the member list
is how Discord roles, the only permission source, reach FredPD (ADR-010). The
Node gateway is off by default and is not needed to run any of this.

## Working on it

`CLAUDE.md` at the root, and in `web/`, `gateway/` and the core resource, carry
the conventions for each area. `.claude/` holds the review subagents
(security, UI, i18n, performance), task skills, and hooks that block the things
the invariants forbid — editing a shipped migration, writing a secret into the
repo, hand-editing generated code.

Contributions follow the definition of done in spec 15: acceptance criteria met,
invariants respected, tests passing, `en` and `sv` complete, permissions
recorded, and an ADR when a decision changed.
