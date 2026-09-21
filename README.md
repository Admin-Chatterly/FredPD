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

**M0–M3 complete. M2 records, M4 dispatch and M5 surveillance are in, and M6
has its first piece.** The platform core, the registers, the evidence and
forensics chain, dispatch, the records half of M2 — anmälan, förundersökning,
frihetsberövande, tvångsmedel and spaningsuppdrag — M5's secret coercive
measures — HAK, HRA, spårsändare, kameraövervakning, tingsrätt-decided unlike
M2's — and M6's åtal och dom — the prosecutor's charging decision and the
court's disposition, picking up where `frihet.haktning` leaves off — are
built and tested. The gateway's media store, PDF renderer and retention
scheduler are built too, standalone and tested, though nothing in the core
resource calls them yet — that bridge (`server/bridges/gateway/*.lua`, spec
3.7) needs a verified Lua HMAC-SHA256 implementation this repository does not
have, and shipping an unverified one was judged worse than leaving the gap
open. Personnel and booking are M6's other two pieces and are next; see the
roadmap in spec section 17.

Two decisions that shape everything below: the framework is **ESX** (ADR-005),
and the procedure is **Swedish** rather than US workflows with Swedish labels
(ADR-014). The second is structural, not cosmetic — see the ADR for the four
places where it produces genuinely different software.

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
- **The registers**: the master name index with phonetic search, vehicles,
  firearms, and hot-file hits with a confirmation step (spec 7.2–7.5).
- **Crime scenes, evidence and the lab**: collection, chain of custody, the
  property room, analysis and the forensic indexes (spec 8).
- **Dispatch**: calls, the unit board, live positions, beats, broadcasts and the
  ALPR hotlist (spec 7.16–7.18).
- **Brottskatalogen** with straffskalor and BrB 26:2 sentencing for several
  offences at once, versioned so a change never alters a past record (7.10).
- **Anmälan och förundersökning**: the report workflow, locking, tilläggsuppgifter
  and the investigation's own lifecycle (7.7, 7.8). An officer cannot approve
  their own anmälan, and no permission reaches that rule.
- **Frihetsberövande**: gripande → anhållande → häktning, with the RB 24:12 and
  RB 24:13 deadlines counted down on the screen (7.9).
- **Tvångsmedel och efterlysning**: husrannsakan, kroppsvisitation and wanted
  notices, with `HasSearchWarrant` for door and raid scripts (7.12, §14).
- **Spaningsuppdrag**: lookouts on people, vehicles or a description alone,
  feeding the hot-file check (7.13).
- **Surveillance**: HAK, HRA, spårsändare and kameraövervakning, requested by
  an åklagare and only ever granted or refused by a domare, with
  `HasActiveWarrant` for other resources to check (spec 9, §14).
- **Åtal och dom**: the åklagare's charging decision on a redovisad
  förundersökning, and the domare's disposition — never the same session,
  however many permissions it holds. Sentences are checked against
  `Brott.gemensamStraffskala` for the exact charges on the case, the same
  arithmetic the brottskatalog screen shows (7.20).

M2's interface is complete: every register and every workflow in it has a
screen, and the Records module's tabs are the whole of what the M2 routes can
do. M5 and M6's åtal och dom each have their own rail module rather than a
Records tab, since each is a different clearance and a different pair of
decision-makers.

Built and tested, but not reachable from inside the game yet: the **gateway**
service — signed upload/download tokens over a local (or S3-compatible) media
store, WebP thumbnails, a pluggable virus-scan hook, PDF rendering through
headless Chromium from the same editor-JSON contract Tiptap will eventually
produce, and a retention scheduler for query logs, ALPR reads, stale drafts and
old surveillance sessions. It runs and is fully covered by its own test suite,
but the Lua-side bridge that would let FXServer call it does not exist — see
above. `web/index.html`'s CSP already carries a `VITE_MEDIA_HOST` slot for it
either way.

Not built at all yet: **booking**, **citations**, **impound** and
**personnel** (the rest of M6) — and, within court itself, the calendar,
subpoenas, discovery and sealing spec 7.20 marks `[S]` rather than `[M]`.
None of this has run on a live FiveM server: the logic is covered by tests,
and the parts that call game natives are not.

## Layout

```
resources/[fredpd]/
  fredpd/               core: sessions, permissions, records, dispatch, NUI host
  fredpd_forensics/     evidence generation and scene tools      (M3)
  fredpd_surveillance/  device/tracker plumbing, still a boot stub (M5)
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
