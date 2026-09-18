# FredPD — Product & Engineering Specification

Police records, dispatch, evidence and forensics suite for an ESX (es_extended) FiveM server.

| Field | Value |
|---|---|
| Spec version | 0.1 (draft for implementation) |
| Date | 2026-09-17 |
| Owner | Rami |
| Target platform | FiveM (OneSync) + ESX + ox stack, dedicated high-end host |
| Default language | English (`en`), with complete Swedish (`sv`) and custom translation overlays |
| Permission source | Discord roles only |

## How to use this document

- This file is the single source of truth for scope, rules and acceptance criteria. Keep it at `docs/FredPD.md` in the repo.
- Section 0 (Invariants) applies to every line of code. Read it before every task.
- Each module section lists features tagged **MUST** (launch scope), **SHOULD** (planned) or **MAY** (optional), what the feature is based on, and the permissions it needs.
- Section 17 maps everything to GitHub milestones and issues. Section 18 explains how to drive the work with Claude Code.
- When a decision changes this spec, write an ADR in `docs/adr/` and update this file in the same pull request.

## Contents

0. Non-negotiable invariants
1. Product overview
2. Reference systems (what each feature is based on)
3. Architecture
4. Identity, sessions and Discord-based access control
5. Localization
6. UI and UX specification
7. Functional specification (records, dispatch, personnel, court)
8. Evidence, property and forensics
9. Surveillance and interception
10. PD-Span integration (intelligence)
11. Security specification
12. Performance specification
13. Data model
14. Integration API for other resources
15. Quality, testing and CI
16. Deployment and operations
17. Roadmap and GitHub setup
18. Working with Claude Code
19. Open decisions and inputs needed
- Appendices A–G (Swedish terminology, permission catalog, role template, numbering, status tables, command line, references)

---

## 0. Non-negotiable invariants

These rules override convenience, deadlines and any other section.

1. **Server-authoritative.** Clients send intent (IDs, text, a proposed position). The server validates and decides. Authors, officers, agencies, timestamps, record numbers, analysis results and biometric owners are always generated server-side.
2. **Discord roles are the only permission source.** ESX job grades never grant anything. Job and duty state are used only as *context conditions* on top of a Discord-granted permission (see 4.3).
3. **One gateway for client calls.** Every client-to-server call goes through `route()` (session, permission, classification, schema validation, rate limit, audit). No raw `RegisterNetEvent` handler may change state.
4. **Access is checked on the server for every read,** including search results, attachments, prints and exports. Hiding something in the UI is never the control.
5. **No record broadcasts.** Never `TriggerClientEvent(..., -1, record)`. Push only to authorized, subscribed sessions. No sensitive data in state bags.
6. **No hardcoded user-facing text.** Every string goes through locale keys. `en` and `sv` must be complete before a pull request merges.
7. **No secrets on clients.** Secrets live in `set` convars (never `setr`) or gateway environment variables, never in files listed in `files {}`.
8. **SQL is parameterized, schema changes are migrations.** Never edit a migration that has shipped.
9. **Media only through the gateway.** Uploads are re-encoded, served through signed URLs, and the NUI enforces a Content Security Policy that only allows your own media host and `nui://`.
10. **Rich text is stored as editor JSON,** rendered through the editor schema. Raw HTML is never rendered.
11. **The audit log is append-only.** Reads of restricted records are audited too.
12. **The UI follows section 6.** Realistic agency software: no gradients, glass, glow, neon or emoji icons.
13. **Performance budgets in section 12 are acceptance criteria,** not goals.

---

## 1. Product overview

### 1.1 Vision

FredPD is the in-game computer system of a police agency, built to feel like the real software officers, dispatchers, detectives, forensic staff and prosecutors use: fast, dense, keyboard-driven and procedural. Realism comes from real workflows (approvals, chain of custody, lab turnaround, warrant review, hit confirmation), not from visual effects. Everything a player can see is decided by their Discord roles.

### 1.2 Components

| Component | Runs in | Purpose |
|---|---|---|
| `fredpd` | FiveM resource | Core: sessions, permissions, records, dispatch, property room, lab, court, personnel, NUI host |
| `fredpd_forensics` | FiveM resource | In-world evidence generation, scene tools, packaging, destruction mechanics |
| `fredpd_surveillance` | FiveM resource | Wiretaps, radio monitoring, listening devices, trackers (pma-voice) |
| `fredpd_assets` | FiveM resource | Streamed props (MDC tablet, terminals, evidence bags, markers, tape), sounds |
| `gateway` | Node.js service on the same host | Media service, PDF rendering, scheduled jobs, Discord role *actions*, optional web portal. Off by default; role *sync* runs in FXServer (ADR-010) |
| `web` | Built into `fredpd/web/dist` | The NUI application (MDC, station terminal, dispatch console, lab, property room layouts) |
| PD-Span | Your existing system | Integrated as the intelligence module (section 10) |

### 1.3 Personas

| Persona | Primary work |
|---|---|
| Patrol officer | Queries, calls, reports, citations, arrests, scene first response |
| Field supervisor | Report approval, call oversight, use-of-force review |
| Detective / investigator | Cases, warrants, lab requests, interviews |
| Crime scene technician | Scene processing, photography, collection, packaging |
| Lab analyst | Lab queue, analysis, technical review, lab reports |
| Property technician | Intake, storage, custody transfers, audits, disposition |
| Dispatcher | Call intake, unit management, broadcasts |
| Intelligence analyst / source handler | PD-Span: intel reports, surveillance logs, source register |
| Command staff | Statistics, personnel, policy, approvals |
| Internal affairs | Complaints, investigations, early-intervention alerts |
| Field training officer | Trainee evaluations |
| Prosecutor, judge, court clerk | Charging, warrant review, hearings, dispositions |
| Defense attorney | Discovery packages (redacted) |
| Civilian | Complaints, own citations and court dates, 911 |
| System administrator | Configuration, branding, permissions, audit |

### 1.4 In-game access points

Access points are real places or devices. Some features only work at the matching access point (a context condition, section 4.3).

| Access point | How it opens | Layout | Features limited to this access point |
|---|---|---|---|
| Mobile data computer (MDC) | Keybind while seated in an agency vehicle | Compact, night mode default | — |
| Duty tablet | Using the tablet item on foot | Compact, reduced module set | — |
| Station terminal | ox_target on desk computer props or zones | Full | — |
| Property room terminal | Zone in the property room | Full | Evidence intake, release, audits |
| Lab terminal | Zone in the lab | Full | Analysis, technical review |
| Booking terminal | Zone in booking | Full | Booking, mugshot, ten-print capture |
| Dispatch console | Zone or command at the dispatch center | Multi-panel CAD | Call intake, dispatcher tools |
| Courthouse terminal | Zone at the courthouse | Full | Court calendar, dispositions |
| Web portal (later) | Browser, Discord login | Full, no in-world actions | Read, write reports, approvals |

---

## 2. Reference systems — what each feature is based on

Use real systems for **workflow and data structure**, FiveM resources for **game mechanics and integration patterns**. Read the FiveM references for behavior only: they carry their own licenses (several are GPL), so FredPD is written clean-room unless you deliberately accept a license.

| Area | Real-world reference | FiveM reference | What to take |
|---|---|---|---|
| Dispatch (CAD) | Motorola PremierOne / CommandCentral, Hexagon HxGN OnCall, Mark43 CAD, Tyler New World | ps-dispatch, ox_mdt dispatch (units, calls), ps-mdt v3 map and patrol zones | Call card with timestamps, unit status model, command line, premise hazards, stacking queue |
| Records (RMS) | Mark43 RMS, Axon Records, NIBRS incident structure | ps-mdt v3 reports and cases, ox_mdt reports | Structured sections plus narrative, supervisor approval, locked records with supplements |
| MDC experience | In-car MDC software (Mark43 Mobile, Motorola MDC) | — | Night mode, hit banners, F-key status changes |
| Queries and hot files | NCIC-style wanted/stolen files, hit confirmation practice | ps-mdt citizen and vehicle search | Hit banner plus confirmation step, query logging with reason |
| Evidence and property | Axon Evidence, Tracker Products SAFE, BEAST, FileOnQ | noobsystems/evidences (evidence boxes), ps-mdt v3 chain of custody | Barcodes, temporary lockers, two-step intake, custody log, audits, disposition |
| Crime scene | CSI practice: numbered markers, photo log, scene entry log, packaging | noobsystems/evidences (prints, blood, casings, bullets, magazines, residue, rain) | Evidence mechanics, re-implemented server-authoritatively |
| Forensic lab | LIMS products (JusticeTrax LIMS-plus, STARLIMS); CODIS, NGI/AFIS, NIBIN | noobsystems/evidences laptop apps | Request, queue, analysis, technical review, report; database hits are leads |
| Firearms | ATF eTrace, state firearm registries | evidences firearms registry, ps-mdt v3 weapons | Ownership history, tracing, obliterated serial restoration |
| Warrants and court | Electronic warrant systems with judge review and e-signature; court case management | ps-mdt v3 court and DOJ calendar | Probable cause affidavit, judge decision, return of service, dispositions |
| Intelligence | Admiralty/NATO source grading, UK 5x5x5 and 3x5x2 handling models, link-analysis tools | PD-Span | Source and information grading, handling codes, compartments, sanitized dissemination |
| Personnel and IA | IAPro / BlueTeam (early intervention), PowerDMS (policy acknowledgement) | ps-mdt v3 FTO, IA, performance reviews, SOP, awards | Early-intervention thresholds, SOP acknowledgement tracking |
| Citations | Electronic citation systems (TraCS-style) | ps-mdt fines | Citation lifecycle, licence points, contest flow |
| ALPR | Plate reader hotlists and retention policies | Wolfknight radar (wk_wars2x) | Hotlist hits, read retention |
| Swedish vocabulary | Swedish Police systems and registers (RAR, DurTvå, Rakel; Belastningsregistret, Misstankeregistret, Vägtrafikregistret, Vapenregistret; DNA-registret, utredningsregistret, spårregistret) | — | Terminology for `sv.json` (Appendix A) |
| Framework and libraries | — | es_extended, ox_lib, ox_inventory, ox_target, oxmysql, pma-voice, screenshot-basic | Everything in-game |
| Discord permissions | Discord developer documentation | Badger_Discord_API (REST plus cache), discord.js | Gateway bot with role snapshots |
| Tooling | — | overextended/fivem-ts, ps-mdt v3 Svelte 5 web build | Monorepo and build patterns |

Lessons already learned from the noobsystems/evidences code review are encoded in section 11.3.

---

## 3. Architecture

### 3.1 Repository layout

```
fredpd/
├─ CLAUDE.md
├─ docs/
│  ├─ FredPD.md                 # this spec
│  └─ adr/                      # architecture decision records
├─ resources/[fredpd]/
│  ├─ fredpd/                   # core FiveM resource
│  ├─ fredpd_forensics/
│  ├─ fredpd_surveillance/
│  └─ fredpd_assets/
├─ web/                         # NUI app source (builds into resources/[fredpd]/fredpd/web/dist)
├─ gateway/                     # Node.js service
├─ packages/
│  └─ schema/                   # route and entity schemas → generated TS types + Lua validator tables
├─ database/
│  ├─ migrations/               # append-only, numbered; 0001 is the whole schema as first released
│  └─ seeds/                    # code tables, penal code, default permission groups
├─ tools/                       # i18n checker, codegen, load-test harness
├─ vendor/pd-span/              # PD-Span source for integration work (section 10)
└─ .claude/                     # subagents, skills, hooks (section 18)
```

### 3.2 Runtime topology

```
 Players (FiveM client + NUI)
      │  lib.callback via route()          HTTPS signed URLs (images, PDFs)
      ▼                                                   │
 FXServer ── fredpd / fredpd_forensics / fredpd_surveillance
      │  oxmysql                     ▲ loopback HTTP + HMAC
      ▼                              │
 MariaDB  ◄──────── mysql2 ──────── gateway (Node.js)
                                     ├─ Discord gateway + REST (role sync, role actions)
                                     ├─ media store (disk or S3-compatible)
                                     ├─ PDF renderer (headless Chromium)
                                     ├─ scheduler (retention, lab timers, warrant expiry)
                                     └─ web portal (Discord OAuth2), later milestone
 Caddy (TLS) → gateway media + portal
```

### 3.3 Technology choices

| Layer | Choice | Reason |
|---|---|---|
| Server scripts | Lua 5.4 with ox_lib | Matches ESX and the ox ecosystem, best FiveM tooling |
| NUI | Svelte 5 + TypeScript + Vite | Small runtime and fast updates; ps-mdt v3 proves it in production |
| Styling | Tailwind CSS 4 with CSS-variable design tokens | Tokens from section 6 in one place |
| Data in NUI | TanStack Query (cache), TanStack Virtual (long lists), TanStack Table core (grids) | Instant reopen, virtualized grids |
| Rich text | Tiptap, stored as JSON | No raw HTML, schema-validated |
| Map | Leaflet with `CRS.Simple` and self-hosted GTA V tiles, lazy-loaded | Light, proven for GTA maps |
| Icons | Lucide SVG | Consistent, no emoji |
| Gateway | TypeScript on Node.js 24 LTS, Fastify, discord.js, sharp, Playwright (PDF), pino | Mature, well-typed |
| Database | MariaDB 11.4 LTS or newer, InnoDB, `utf8mb4_unicode_ci` | Same DB as ESX; FULLTEXT, generated columns, JSON |
| Monorepo | pnpm workspaces | Shared schema and locale packages |
| Tests | busted (pure Lua modules), Vitest, Playwright | See section 15 |
| Lint | luacheck and lua-language-server diagnostics (with fivem-lls-addon), ESLint, svelte-check, tsc | See section 15 |

Choices can change through an ADR until milestone M1 closes. After that, a change needs a migration plan.

### 3.4 Core resource structure

```
fredpd/
├─ fxmanifest.lua
├─ config/
│  ├─ server.lua        # server-only, never in files {}
│  └─ shared.lua        # safe for clients
├─ locales/             # en.json, sv.json (+ custom/ overlay, git-ignored)
├─ shared/              # enums, constants, locale loader
├─ server/
│  ├─ core/             # route, session, perms, access, validate, audit, ratelimit,
│  │                    # numbers, cache, push, db, migrate, gateway, i18n
│  ├─ bridges/          # framework, inventory, voice, dispatch, phone, jail, billing,
│  │                    # garage, housing, appearance, alpr, doorlock, span
│  └─ modules/<name>/   # service.lua (logic), repo.lua (SQL), routes.lua, events.lua
├─ client/              # nui, access points, status keys, camera (mugshots/photos), avl
└─ web/dist/            # built NUI
```

Rules:
- A module calls another module only through its `service.lua` API, never through its `repo.lua`.
- `service.lua` files contain no natives, so they can be unit-tested with busted.
- Bridges are the only place that references other resources by name.

### 3.5 Route layer

Every client call is a route. The wrapper is the security boundary.

```lua
-- server/core/route.lua (shape, not final code)
route {
    name     = 'warrant.request',          -- callback: 'fredpd:warrant.request'
    perm     = 'court.warrant.request',     -- Discord-derived permission key
    context  = { onDuty = true },           -- optional context conditions
    schema   = 'WarrantRequest',            -- generated from packages/schema
    limit    = { per = 10, window = 60 },   -- per session
    audit    = 'warrant.requested',
    handler  = function(session, input)
        -- session.officerId, session.agencyId come from the server, never from input
        return warrants.request(session, input)
    end
}
```

Wrapper order: session exists → session not stale → permission → context conditions → rate limit → schema (types, enums, lengths, unknown keys dropped) → handler in `pcall` → record-level access checks inside services → audit → response.

Response envelope: `{ ok = true, data = ... }` or `{ ok = false, err = 'code', fields = { ... } }`. Error codes: `no_session`, `forbidden`, `context`, `rate_limited`, `invalid`, `not_found`, `conflict` (stale version), `restricted`, `stale_permissions`, `internal`.

#### 3.5.1 The public tier

A session is opened only for a player with an `fpd_officers` row, so the wrapper
above is reachable by officers and by nobody else. Section 8 needs the opposite
for two of its calls: 8.3 requires that *any* player leaves traces — the whole
value of a fingerprint is that the person who left it is not an officer — and
8.10 requires that destroying evidence is "available to every player … Police-only
restrictions must never block criminal gameplay."

Those two calls use `route.public`, which is the same gateway (invariant 3), the
same envelope, and the same registration:

```lua
route.public {
    name    = 'forensics.destroy',
    schema  = 'ForensicsDestroy',
    limit   = { per = 20, window = 60 },    -- required, not defaulted
    handler = function(src, input)          -- a server id, never a session
        return destroy(src, input)
    end
}
```

Wrapper order: rate limit → schema → handler in `pcall` → response. What it drops
is session, staleness, permission, context and audit — each of which needs a
session to mean anything, so a public route declaring one fails at load rather
than appearing to be protected.

The handler receives a numeric `src` and not a session. The signature is not by
itself the control, and saying it is overstates the design: a handler holding a
server id can write `FredPD.Core.session.get(src)` and have the session back, so
"a public handler has no identity" is a convention that nothing in Lua enforces.

What enforces it is CI. `tools/wiring-check.ts` reads the body of every
`route.public` handler and fails the build when it names the session, the
permission set, an access check or a repo. So the guarantee is this: **a public
handler is handed a number, and a public handler that reaches for identity or
for a record does not merge.** What it is left with is the in-memory forensics
grid, which holds no records and answers nothing (8.11).

The check reads handler bodies, and only handler bodies. A function defined
outside the handler and called from it is not covered — `forensics.destroy`
has one, `auditDestruction`, which reads a `discordId` off a session that is
usually absent and writes one append-only audit row. That is a deliberate
exception with its reasoning written at the call site, not a loophole to use
again: a helper reached from a public route has to be read with the same
question in mind, because CI will not ask it. A third public route is a decision
to be argued for in an ADR, not a convenience. See ADR-013.

### 3.6 Realtime updates

- Sessions subscribe to channels while a view is open: `unit:<id>`, `call:<id>`, `record:<type>:<id>`, `board:<agency>`, `map:<agency>`.
- The server pushes versioned deltas. A client that detects a version gap refetches.
- Map positions (AVL) go out every 1–2 seconds, only to sessions with the map open.
- Pushes are filtered through the same access checks as reads.

### 3.7 Gateway interface

- **FXServer → gateway:** `PerformHttpRequest` to `http://127.0.0.1:<port>` with an HMAC signature and timestamp. Used for media upload tokens, PDF rendering, Discord role actions.
- **Gateway → FXServer:** `SetHttpHandler` in `fredpd`, accepting loopback requests only, HMAC-signed, with a 30-second replay window. Used for role changes, lab timer completions, scheduled jobs.
- **Reliability:** an outbox table on both sides with retries, so a gateway restart never loses events.

### 3.8 Bridges

| Bridge | Responsibilities | Default implementation |
|---|---|---|
| framework | Characters, names, DOB, phone, jobs, duty, licences | es_extended |
| policejob | Duty state, rank, armory, cloakroom, impound | p_policejob (section 3.11) |
| society | Agency funds, society-owned vehicles | esx_society |
| textui | In-world prompts ("Press E to open the terminal") | esx_textui |
| menu | In-world option menus and input dialogs | esx_menu_dialog |
| garage | Agency motor pool vehicles (section 7.31) | Built-in, over society |
| inventory | Items, metadata, stashes, hooks, weapons | ox_inventory |
| target | Interactions | ox_target |
| voice | Radio channels, voice targets | pma-voice |
| dispatch | Incoming alerts from other scripts | Built-in API, optional ps-dispatch adapter |
| phone | Numbers, 911 calls, photos | Configurable (lb-phone, npwd, yseries) |
| jail | Sentence handoff, release | Configurable |
| billing | Fines and fees | Configurable |
| garage | Vehicle ownership, impound state | Configurable |
| housing | Properties and addresses | Configurable |
| appearance | Gloves, footwear, clothing descriptors | illenium-appearance or equivalent |
| alpr | Plate reads | Wolfknight wk_wars2x |
| doorlock | Door usage (prints), warrant-gated doors | ox_doorlock |
| span | PD-Span integration | Section 10 |

Each bridge checks the target resource's state and version at startup and logs a clear error when something is missing.

### 3.9 Configuration

- **One file: `config/server.lua`** — the Discord bot token and guild, the agency, rate limits, and the gateway (off by default). It is in `server_scripts` and never in `files {}`, so nothing in it reaches a client. `config/shared.lua` carries what the client legitimately needs: environment, locale, timezone (ADR-010).
- Convars still override every value where one is set, for hosts that template their configuration: `set fredpd:discord_token`, `set fredpd:discord_guild`, `set fredpd:env`, and — because the client reads them — `setr fredpd:locale`, `setr fredpd:timezone`. A normal install needs none of them.
- Feature flags per module in `config/shared.lua`.
- Agencies: id, name, short name, logo, seal, accent color, numbering prefixes, jurisdiction polygons, radio channels, report letterhead text.

### 3.10 In-game configuration and world placement

Nothing with a world position is hardcoded. Every terminal, lab bench, booking
station, dispatch console, courthouse desk and motor pool ped is a **placement**
row in `fpd_placements`, created and edited in game by an administrator holding
`admin.placement.edit`. A server operator never edits a Lua config to move a
desk, and never needs a restart to do it.

A placement carries:

| Field | Meaning |
|---|---|
| `kind` | What it opens — an access point (1.4), a motor pool ped, a scene-tool bench |
| `agency_id` | Which agency owns it; `NULL` means shared |
| `coords`, `heading` | Where it is |
| `interaction` | `prop` (bind to a nearby prop model), `ped` (spawn one), or `zone` (a radius with no entity) |
| `model` | Prop or ped model, for the `ped` and `prop` interactions |
| `radius` | Interaction distance, default 1.5 m |
| `label_key` | Locale key for the prompt, never a literal string (invariant 6) |
| `enabled` | Off without deleting, so a station can be closed for an event |

**The editor.** `/fredpd placement` opens placement mode: aim at a prop to bind
it, or place a ped with a live preview, then pick the `kind` from a menu. Move,
rotate, disable and delete are the same mode. Every write goes through a route
with `admin.placement.edit` and is audited like any other change (invariant 11).

**A placement decides *where*, never *who*.** It binds a prop to a UI element;
it does not grant access to that element. Permission still comes from Discord
roles, checked on the server for every route the element calls (invariants 2
and 4). Disabling a placement hides an entrance, not a permission.

**Placements are not trusted from the client.** A client that calls a route
"from" a placement sends the placement id, and the server verifies the player is
actually within `radius` of that placement's coordinates before honouring the
access-point context condition (4.3). Otherwise the access-point rule would be
worth nothing: any client could claim to be standing in the property room.

Placements are pushed to clients as world geometry only — coordinates, models
and label keys, for the placements that exist. They carry no permission data,
because a client knowing a door exists is not the same as a client being able to
open it.

### 3.11 Coexistence with p_policejob

FredPD does not replace the police job resource. `p_policejob` keeps the
in-world job — duty toggle, armory, cloakroom, impound — and FredPD owns
records, dispatch, evidence, lab, court, intelligence and the MDT.

The `policejob` bridge is the only place that names it. Duty and rank are read
through that bridge as **context conditions** (4.3), never as grants: a
`p_policejob` rank grants nothing in FredPD, exactly as an ESX job grade does
not (invariant 2).

Where the two overlap, the rule is one owner per concern:

| Concern | Owner |
|---|---|
| Duty toggle, armory, cloakroom | `p_policejob` |
| Impound and tow (7.15) | `p_policejob` |
| Agency motor pool (7.31) | FredPD |
| MDT, records, CAD, evidence, court | FredPD |
| Permissions for any of the above | FredPD, from Discord roles |
- Code tables (call types, dispositions, offences, statuses) live in the database and are seeded from `database/seeds`.

---

## 4. Identity, sessions and Discord-based access control

### 4.1 Identity model

- Player → Discord ID (`GetPlayerIdentifierByType(src, 'discord')`, never from the client) → roster entry → bound character (the ESX character identifier, e.g. `char1:license:…`).
- A Discord user can hold one bound character per agency. FredPD refuses to open on any other character ("This character is not registered as agency personnel"). This stops agency access being used on a criminal alt.
- DOJ, defense and civilian access points bind the same way.
- A player without a Discord identifier gets no access and sees an instruction to link Discord.

### 4.2 Discord role sync

- FXServer calls the Discord API itself, with a bot token from `config/server.lua` and the Server Members privileged intent, and writes `fpd_discord_members (discord_id, roles, synced_at)`. This was originally the gateway bot's job; it moved so that a normal install deploys no second service (**ADR-010**).
- **Two triggers:** the whole guild on a timer (`discord.refreshMinutes`, default 10), so a role *removed* in Discord takes effect without the member doing anything; and each player as they connect, so a role *granted* seconds ago is live when they join. After a successful refresh every open session is recomputed, and an open MDT loses pages it may no longer see.
- **A failed fetch writes nothing.** Rows age instead, and the outage policy below narrows access on its own. Stamping `synced_at` without a role list Discord actually returned forges the one signal that policy reads, and is forbidden — including from outside the application, such as a cron job.
- **Outage policy:**
  - Snapshot older than `perms.sensitive_stale_after` (default 15 minutes): approvals, releases, deletions, intelligence and surveillance actions are blocked.
  - Snapshot older than `perms.stale_after` (default 6 hours): read-only mode.
- **Role actions from FredPD** (hire, promote, demote, suspend, dismiss) still belong to the gateway, which holds a bot able to *write* roles. Not built. Discord stays the single source of truth either way, and that bot's Discord role must sit above the roles it manages.

### 4.3 Permission model

- **Permission keys:** `<area>.<object>.<action>`, optionally with a scope, for example `rms.report.approve` or `evidence.item.release`. Full catalog in Appendix B.
- **Permission groups:** named bundles of keys. Groups can inherit from other groups.
- **Role map:** Discord role ID → groups, scoped to an agency.
- **Effective permissions:** the union of groups from all of a user's roles, per agency. Computed once per role change and cached in the session, so checks are constant-time.
- **Storage:** seeded from `config/permissions.lua` into the database, editable in Admin with `admin.permissions.edit`, every change audited, exportable and importable as JSON.
- **Context conditions** (per permission, configurable): `onDuty`, `accessPoint` (for example `evidence.item.intake` requires `property_terminal`), `inAgencyVehicle`, `boundCharacter`. These restrict a granted permission; they never grant one.

### 4.4 Pages and navigation

- Every page declares the permissions it requires. Navigation only shows allowed pages; routes enforce the same rule.
- Opening a forbidden deep link shows "No access" with a "Request access" action that creates a supervisor queue item.

### 4.5 Record-level access (files)

- **Classification levels** (configurable, localized): `open`, `internal`, `restricted`, `confidential`, `secret`.
- **Compartments** (need-to-know groups, granted by Discord roles), for example `internal_affairs`, `narcotics`, `homicide`, `intelligence`, `sources`.
- **Record access control:** owning agency, classification, compartments, explicit grants (user or role, with expiry), sealed flag (court-sealed).
- **Read rule:** clearance ≥ classification AND membership in every compartment on the record, or an explicit grant.
- **Restricted stubs:** per compartment, a record the user cannot read is either hidden or shown as "Restricted record — contact <unit>".
- **Break-glass access:** users with `records.breakglass` can open a restricted record after entering a written reason. Access lasts 30 minutes, is audited, and notifies the record owner and internal affairs.
- **Attachments** inherit the record's access control and can be stricter.
- **Field-level redaction:** fields such as source identity, victim address and medical notes need their own permission (`fields.<name>.view`). Prints and exports apply the same redaction.
- **Cross-agency sharing:** configured per data type as mutual or one-way (same idea as ps-mdt v3's sharing config).

### 4.6 Sessions

- A session is created when FredPD opens and holds: discord_id, officer_id, citizenid, agency, groups, clearance, compartments, access point, unit and duty state.
- Sessions are destroyed on `playerDropped`, so server ID reuse can never inherit access.
- Idle lock after a configurable time. Unlocking requires the officer's personal PIN if the agency enables PINs (a realistic MDC sign-on).

---

## 5. Localization

### 5.1 Files and loading

- `locales/en.json` is the default and the reference key set. `locales/sv.json` ships complete.
- Custom translations go in `locales/custom/<lang>.json`. This folder is git-ignored and never overwritten by updates. At startup the loader merges base file → custom overlay. Admins can reload translations with a command.
- A new language is added by dropping `locales/custom/<lang>.json` (full or partial). Missing keys fall back to English and are logged once.
- Language selection: `setr fredpd:locale sv`. If enabled, users can override the language in their settings.
- The same JSON files feed Lua (server notifications through ox_lib's locale module) and the NUI.

### 5.2 Keys and formatting

- Keys are namespaced `module.screen.element`, for example `evidence.intake.accept`.
- Placeholders use `{name}`. Plurals use `key.zero` / `key.one` / `key.other`.
- Dates, times and numbers are formatted with `Intl`, using a locale map (`en` → `en-US`, `sv` → `sv-SE`) and the `fredpd:timezone` convar. All timestamps are stored in UTC.
- Date display format is configurable (default ISO `YYYY-MM-DD HH:mm`, which reads naturally in Swedish and in real RMS software).
- Currency symbol and placement are configurable.
- Agency-specific vocabulary (for example "Deputy" instead of "Officer") is a custom overlay, not a code change.

### 5.3 Database content

- Code tables (call types, dispositions, offences, statuses, penal code) store a label key or an `i18n` JSON column (`{"en": "...", "sv": "..."}`), never a single hardcoded label.
- Penal code entries carry per-locale titles and descriptions.

### 5.4 Tooling and rules

- `pnpm i18n:check` fails CI when `sv.json` misses a key, has an unused key, or has placeholder mismatches.
- An ESLint rule forbids string literals in Svelte markup. A luacheck-based script flags literal strings passed to notification helpers.
- Swedish text uses real Swedish police and legal vocabulary (Appendix A), not literal translation. Where Swedish law has no equivalent (US-style warrants, for example), the nearest Swedish concept is used and noted. A native speaker (you) reviews `sv.json` before each release.

---

## 6. UI and UX specification

### 6.1 Direction

FredPD should look like software an agency actually bought: calm, dense, predictable and keyboard-driven. It follows the "accessible, data-dense government software" pattern rather than consumer or SaaS styling. Personality comes from the agency's branding (logo, name, accent color) and from correct terminology, not from decoration.

### 6.2 Design tokens

**Day theme**

| Token | Hex | Use |
|---|---|---|
| `ink` | `#1D232B` | Primary text |
| `ink-muted` | `#5B6672` | Secondary text, captions |
| `paper` | `#FFFFFF` | Record surfaces, forms, grids |
| `canvas` | `#E6E9ED` | Application background |
| `rule` | `#C3CAD2` | Borders, grid lines |
| `agency` | `#1F3B5A` | Title bar, primary buttons (overridden per agency) |
| `alert` | `#B3261E` | Warrants, officer safety, emergency |
| `caution` | `#A15C00` | Pending, expiring, needs attention |
| `clear` | `#1E6B3A` | Approved, available, no hits |
| `focus` | `#2F6FDB` | Keyboard focus ring, selected row |

**Night theme (MDC default)**: canvas `#14181D`, paper `#1B2027`, ink `#D5DBE1`, ink-muted `#8B96A1`, rule `#2C333C`. Semantic colors are lightened just enough to keep 4.5:1 contrast. No pure black.

**Typography**
- UI text: Segoe UI, falling back to Tahoma and Arial. FiveM runs on Windows, so this is the native system font: zero download and exactly what real Windows-based agency software uses.
- Identifiers only (plates, serials, case, evidence and DNA/print IDs, call numbers): Consolas, so characters like 0/O and 1/I are unambiguous.
- Base size 13 px, grids 12.5 px, section headings 15 px semibold, record titles 17 px semibold. Line height 1.35. Tabular numerals in grids.

**Shape and depth**: 2 px radius on inputs and buttons, 0 px on panels and grids, 1 px borders. Shadows only on menus and dialogs.

**Motion**: at most 120 ms, only in response to a user action (open, expand, confirm). No decorative animation. Respect reduced motion.

**Icons**: Lucide at 16 px. Primary actions always show a text label.

### 6.3 Application shell

```
┌────────────────────────────────────────────────────────────────────────────────┐
│ [logo] Los Santos Police Department — FredPD        1-ADAM-12   Available  14:32│  title bar
├──────────┬──────────────────────────────────────────────────────┬──────────────┤
│ Query    │ Command: P 45ABC123_                                 │ Alerts       │
│ Dispatch ├──────────────────────────────────────────────────────┤ Wanted hit 1 │
│ Records  │ [DOE, John ×] [Report LSPD-26-000123 ×] [Call 0042 ×]│ BOLOs 3      │
│ Evidence ├──────────────────────────────────────────────────────┤ Messages 2   │
│ Lab      │                                                      │              │
│ Intel    │              active record workspace                 │              │
│ Court    │                                                      │              │
│ Personnel│                                                      │              │
│ Admin    │                                                      │              │
├──────────┴──────────────────────────────────────────────────────┴──────────────┤
│ F1 Available  F2 En route  F3 On scene  F4 Busy  F5 Transport  F9 Emergency  ● │  status bar
└────────────────────────────────────────────────────────────────────────────────┘
```

- Title bar: agency logo, agency name, system name, unit, unit status, clock.
- Module rail: icon plus label, only modules the user may open.
- Command line: always available (Appendix F).
- Tabbed workspace: several records open at once, with unsaved-change markers.
- Context panel: alerts and flags for the subject in the active tab, unread messages.
- Status bar: F-key status legend, connection indicator, pending notifications.

**Person record**

```
┌ Person  DOE, John A.    DOB 1994-03-12    P-000431 ────────────────────────────┐
│ WANTED — Felony warrant W26-00088. Confirm before taking action.   [Confirm]   │  alert banner
├───────────────┬────────────────────────────────────────────────────────────────┤
│ [photo]       │ Sex M   Height 183 cm   Build Medium   Hair Brown   Eyes Blue   │
│ 2026-09-02    │ Phone 555-0142   Address 1123 Grove Street                      │
│ Photo 1 of 3  │ Cautions: Armed, Officer safety   Gang: Families               │
├───────────────┴────────────────────────────────────────────────────────────────┤
│ Summary | Involvements | Arrests | Warrants | Vehicles | Firearms | Licences   │
│ Biometrics | Notes | Intelligence (restricted) | Attachments | Access log      │
├────────────────────────────────────────────────────────────────────────────────┤
│ Date        Type     Number           Role      Status                         │
│ 2026-09-14  Report   LSPD-26-000411   Suspect   Approved                       │
└────────────────────────────────────────────────────────────────────────────────┘
```

**Evidence intake (property room terminal)**

```
Evidence number: [E26-001234        ] [Look up]
┌ E26-001234 — Firearm (pistol) ─────────────────────────────────────────────────┐
│ Case LSPD-C26-00045    Collected by Ofc. Berg (1-ADAM-12)   2026-09-17 13:02   │
│ Seal: intact            Packaging: firearm box                                  │
│ Storage: [Firearms vault      v] [Shelf B-04 v]      Condition: [           ]  │
│ [Accept into custody]   [Reject with reason]                                    │
└────────────────────────────────────────────────────────────────────────────────┘
Custody: 13:02 Collected (Berg) → 13:10 Temporary locker 3 → 13:40 Accepted (Lind)
```

### 6.4 Interaction rules

- **Keyboard first:** command line, F-keys for unit status, `Ctrl+Enter` submits, `Esc` closes dialogs and tabs, `Ctrl+Tab` switches tabs. Every action works without a mouse.
- **Forms:** labels above fields, required marker, inline validation on blur and submit, code pickers with typeahead (code and description). Submit is never disabled; errors are shown after the attempt.
- **Drafts:** autosave every 10 seconds; drafts survive disconnects.
- **Grids:** sortable, resizable, column chooser, sticky header, virtualized, keyboard row navigation, CSV export behind a permission.
- **Hits:** a query hit is a full-width red banner with a confirmation step, never just a toast.
- **Dialogs:** only for legal or destructive actions (sign, approve, release, delete), with verb labels ("Release item", not "OK").
- **Empty states:** say what is missing and offer the primary action.
- **Urgent events** (emergency button, officer safety): full-width banner plus tone.
- **Printing:** print preview with agency letterhead.
- **Settings:** density (compact/comfortable), text scale 90–125 %, theme (day/night/auto by in-game time).

### 6.5 Branding and media

- Per agency: name, short name, logo (SVG sanitized or PNG), seal, accent color, report header and footer text, classification watermark for prints.
- The sign-on screen shows agency logo, system name and an "Authorized use only; activity is logged" notice.
- Logos and all images go through the gateway media service (section 3.7).

### 6.6 Rejected in review

Gradients, mesh or aurora backgrounds; glassmorphism and backdrop blur; neon or glow; card grids for tabular data; oversized hero numbers; emoji as icons; all-caps eyebrow labels; decorative or entrance animations; pill-shaped everything; placeholder-only inputs; toast-only critical information; fake loading effects (lab time is real simulated server time shown as queue status).

### 6.7 Quality floor

Contrast at least 4.5:1, visible focus on every control, no meaning by color alone, reduced motion respected, works from 1280×720 up to 4K with text scaling, Playwright screenshot tests for key screens in both themes and both languages.

---

## 7. Functional specification

Each module lists features with a tag: **[M]** MUST (launch), **[S]** SHOULD (planned), **[O]** MAY (optional). Milestones refer to section 17.

### 7.1 Sign-on, unit and status (M1)

- [M] Sign-on screen with agency branding and authorized-use notice; identity from Discord plus bound character.
- [M] Unit log-on: callsign, vehicle (auto-detected when in an agency vehicle), partner(s), assignment (beat, division).
- [M] Unit status via F-keys and command line: Available, En route, On scene, Busy, Transporting, At station, Out of service, Emergency. Every change is timestamped in `fpd_unit_status_log`.
- [M] Duty integration: sign-on sets ESX duty through the framework bridge (configurable).
- [S] Personal PIN and idle lock.
- [S] Day/night theme switching by in-game time.

### 7.2 Queries and hot-file hits (M2)

- [M] Unified query: person (name, DOB, phone, ID number), plate, VIN, firearm serial, phone number, address.
- [M] Phonetic name search (MariaDB `SOUNDEX` on a normalized index) and partial matches, ranked.
- [M] Hot-file checks on every query result: active warrants, BOLOs, stolen vehicle, stolen firearm, protection orders, officer-safety cautions.
- [M] Hits show a red banner and require a confirmation step before the hit is treated as confirmed (real hit-confirmation practice).
- [M] Every query is logged (who, what, when, access point). Queries into restricted data require a reason or case number.
- [S] Recent queries list per unit; one-click re-run.
- **Based on:** NCIC-style query and hit confirmation; ps-mdt citizen and vehicle search.
- **Permissions:** `query.person.run`, `query.vehicle.run`, `query.firearm.run`, `query.phone.run`, `query.address.run`, `query.log.view`.

### 7.3 Persons — master name index (M2)

- [M] Identity from the framework (name, DOB, sex, phone), with FredPD-owned extensions.
- [M] Descriptors: height, weight, build, hair, eyes, scars/marks/tattoos with photos.
- [M] Photo history (mugshots and field photos) with dates and source.
- [M] Aliases and monikers; known addresses; phone numbers.
- [M] Licences (driving, weapons, hunting, pilot, business), with status and points (bridge to framework licences).
- [M] Linked vehicles, firearms, properties; involvements in reports (suspect, victim, witness, reporting party).
- [M] Criminal history: arrests, charges, dispositions, convictions (only final court dispositions count as convictions).
- [M] Cautions and flags with expiry: armed, violent, officer safety, mental health (restricted field), gang affiliation.
- [M] Biometrics on file: "Fingerprints on file" and "DNA on file" with index and date. True biometric values are never shown (section 8.1).
- [M] Notes with classification.
- [S] Known associates and organisation membership (shared with the intelligence module, access-controlled).
- [S] Deceased flag and missing-person status.
- [O] Record sealing and expungement (court-ordered).
- **Based on:** RMS master name index; ps-mdt v3 citizen profiles.
- **Permissions:** `rms.person.view`, `rms.person.edit`, `rms.person.photo.upload`, `rms.person.caution.edit`, `fields.mental_health.view`.

### 7.4 Vehicles (M2)

- [M] Registration from the garage bridge: plate, model, color, VIN (generated once and stored), owner, registration and insurance status.
- [M] Plate history (plate changes), flags (stolen, wanted, BOLO), impound history, involvements.
- [M] Report a vehicle stolen (owner via civilian flow or officer).
- [S] Evidence on the vehicle (prints, blood, bullets) listed with access control.
- [S] ALPR read history (section 7.18).
- **Permissions:** `rms.vehicle.view`, `rms.vehicle.edit`, `rms.vehicle.flag`.

### 7.5 Firearms registry (M2)

- [M] Serial, make, model, type, caliber, status (registered, lost, stolen, seized, destroyed, agency-issued).
- [M] Ownership history with every transfer; automatic registration on purchase through the ox_inventory `buyItem` hook.
- [M] Duty weapons registered to the agency and assigned to officers.
- [M] Report lost or stolen; hot-file hit on query.
- [S] Tracing: from a recovered firearm to first purchaser and every transfer (eTrace-style trace report).
- [S] Obliterated serial handling: filed serials become "obliterated"; the lab can attempt restoration (section 8.9).
- [S] Link to ballistic signatures in the ballistics database.
- **Permissions:** `rms.firearm.view`, `rms.firearm.edit`, `rms.firearm.trace`.

### 7.6 Locations and premises (S, M4)

- [S] Address index (housing bridge plus manual), premise hazards (dogs, weapons, hostile occupants), key holders, incident history at the address.
- [S] Premise hazards appear automatically on dispatch call cards.
- **Permissions:** `rms.location.view`, `rms.location.hazard.edit`.

### 7.7 Incident reports (M2)

- [M] Report types: incident/offence, arrest, supplemental, traffic collision, use of force, vehicle pursuit, death investigation, missing person, found/safekeeping property, field interview, traffic stop.
- [M] Structured sections, following the NIBRS structure: offences (code picker), persons with roles, property (stolen, recovered, seized, evidence), vehicles, narrative (rich text).
- [M] Templates per report type; required fields enforced per type.
- [M] Pre-fill from a dispatch call (location, times, involved units and persons).
- [M] Drafts with autosave; co-authors.
- [M] Workflow: Draft → Submitted → Returned (with supervisor comments) → Approved. Approved reports are locked.
- [M] After approval, changes only through a supplemental report or a supervisor-approved amendment. Every version is kept.
- [M] Electronic signature (name, badge number, timestamp) at submission and approval.
- [M] Evidence and attachments linked (access-controlled).
- [S] Print and PDF with letterhead and classification watermark.
- [S] Void with reason (supervisor), never delete.
- [O] Live co-editing (as in ps-mdt v3).
- **Based on:** Mark43/Axon RMS workflows; NIBRS; ps-mdt v3 and ox_mdt reports.
- **Permissions:** `rms.report.create`, `rms.report.edit.own`, `rms.report.submit`, `rms.report.approve`, `rms.report.return`, `rms.report.void`, `rms.report.view.<type>`.

### 7.8 Case management (M2 basic, M6 full)

- [M] Case number, type, lead investigator, assigned team, status (Open, Active, Suspended, Closed) and clearance (cleared by arrest, exceptionally cleared, unfounded, referred).
- [M] Linked reports, persons (with roles), vehicles, firearms, evidence, warrants, lab requests.
- [M] Chronological case timeline built from linked events.
- [M] Case notes with classification and compartments.
- [S] Tasks and leads with assignee and due date.
- [S] Solvability factors and supervisor review dates.
- [S] Prosecution package: bundle of selected, redacted items for the prosecutor (section 7.20).
- **Permissions:** `inv.case.create`, `inv.case.view`, `inv.case.edit`, `inv.case.assign`, `inv.case.close`.

### 7.9 Arrests and booking (M2 arrest, M6 booking)

- [M] Arrest record: charges (from penal code), time, place, arresting officer(s), rights advisement with timestamp, force used (links to a use-of-force report).
- [S] Booking at the booking terminal: mugshot with height chart (screenshot-basic with a fixed camera), ten-print capture (adds the person to the fingerprint index), DNA reference swab when policy allows.
- [S] Property inventory of the arrestee (dedicated ox_inventory stash per booking, returned on release).
- [S] Sentence and bail handoff to the jail bridge; release record.
- **Permissions:** `rms.arrest.create`, `booking.create`, `booking.biometrics.capture`, `booking.release`.

### 7.10 Penal code and sentencing (M2)

- [M] Code table: code, title, class (felony, misdemeanor, infraction), fine, jail time, licence points, enhancements, lesser-included offences. Localized titles.
- [M] Versioned: a change never alters past records; records store the version used.
- [M] Sentencing calculator with totals, enhancements and reductions (plea, cooperation).
- **Permissions:** `admin.penalcode.edit`, `court.sentence.calculate`.

### 7.11 Citations (M6)

- [M] Traffic, parking and criminal citations with offence codes, location, vehicle, fine and points.
- [M] Lifecycle: issued → paid, contested (goes to court) or overdue; fines through the billing bridge; points on the licence.
- [S] Written warnings recorded without a fine.
- **Permissions:** `rms.citation.issue`, `rms.citation.void`, `court.citation.adjudicate`.

### 7.12 Warrants (M2)

- [M] Types: arrest, search (person, vehicle, address), bench, surveillance (section 9).
- [M] Application with probable-cause statement, linked case and evidence.
- [M] Judge review (DOJ role): approve with conditions and expiry, or deny with reason. Electronic signature.
- [M] Lifecycle: Requested → Approved or Denied → Active → Served (return of service) / Recalled / Expired.
- [M] Active arrest warrants create hot-file hits; search warrants define scope and validity window.
- [M] Export `HasSearchWarrant(targetType, targetId)` so raid and door scripts can require a valid warrant (section 14).
- [S] Emergency (exigent) entries logged with required justification and after-the-fact review.
- **Permissions:** `court.warrant.request`, `court.warrant.review`, `court.warrant.recall`, `rms.warrant.serve`.

### 7.13 BOLOs and attempts to locate (M2)

- [M] Person and vehicle BOLOs with photos, reason, priority, area, expiry.
- [M] Automatic hits on queries and ALPR reads; auto-resolve on arrest or impound.
- [M] Shown on the roll-call board and context panel.
- **Permissions:** `rms.bolo.create`, `rms.bolo.cancel`, `rms.bolo.view`.

### 7.14 Field interviews and stop data (S, M6)

- [S] Field interview cards (who, where, why, associates, vehicle).
- [S] Traffic and pedestrian stop data (reason, search conducted, result), feeding statistics.
- **Permissions:** `rms.fi.create`, `rms.stops.create`.

### 7.15 Impound and tow (M6)

- [M] Impound with reason, hold type (standard, investigative hold, evidence hold), lot, vehicle inventory.
- [M] Fees computed from dates, not timers (same approach as ps-mdt v3), capped.
- [M] Release requires fees paid and, for holds, the investigator's release authorization.
- [S] Impound resolves matching BOLOs.
- **Permissions:** `rms.impound.create`, `rms.impound.release`, `rms.impound.hold.release`.

### 7.16 Dispatch (CAD) (M4)

- [M] Call intake: from the phone bridge (911), from other scripts through `CreateCall`, or manually by a dispatcher.
- [M] Call card: number, type, priority (P1–P4), location, caller, narrative log, units, premise hazards, linked persons and vehicles, timestamps (received, dispatched, en route, on scene, cleared).
- [M] Pending queue with stacking by priority and age.
- [M] Unit board: every unit, status, assignment, time in status.
- [M] Recommend closest available units by position.
- [M] Assign, self-assign, add units, transfer lead unit, clear with disposition code.
- [M] Emergency button: P1 call at the officer's position, map highlight, tone for all dispatchers and units in range, cannot be cleared without supervisor acknowledgement.
- [M] Status timers: a unit on scene too long triggers a welfare-check prompt to dispatch.
- [M] Create report from call (pre-filled).
- [S] Radio integration: suggested pma-voice channel per call, patch channels.
- [S] Plain language or ten-codes (configurable per agency, localized).
- [S] Broadcasts (BOLO, all-units messages).
- **Based on:** PremierOne / HxGN OnCall / Mark43 CAD; ps-dispatch alerts; ox_mdt units and calls.
- **Permissions:** `cad.call.create`, `cad.call.dispatch`, `cad.call.self_assign`, `cad.call.clear`, `cad.unit.manage`, `cad.broadcast`, `cad.console.open`.

### 7.17 Map, vehicle location, beats and geofences (M4)

- [M] Live map with agency units (AVL), calls, emergency markers; lazy-loaded.
- [M] Beats and districts as polygons; calls tagged with beat automatically.
- [S] Geofences with entry and exit alerts (patrol zones, restricted areas).
- [S] Incident heat map for command staff (from statistics).

### 7.18 ALPR and radar (S, M4)

- [S] Plate reads from Wolfknight radar logged with time, place and unit.
- [S] Hotlist checks against BOLOs, stolen vehicles and warrants; hit banner for the unit.
- [S] Read retention (default 30 days) enforced by the gateway scheduler.
- **Permissions:** `alpr.read.view`, `alpr.hotlist.manage`.

### 7.19 Cameras (O, later)

- [O] CCTV, body-worn and dash cameras with live view, as in ps-mdt v3.
- [O] Footage request workflow (request, approve, attach a still frame as evidence).

### 7.20 Court and DOJ (M6)

- [M] Prosecutor intake of case referrals; charging decision (file, decline with reason, request more investigation).
- [M] Court calendar: hearings, trials, officer subpoenas with notifications.
- [M] Dispositions: guilty, not guilty, dismissed, plea; sentences recorded and handed to the jail bridge.
- [S] Discovery packages for defense attorneys: selected items, automatic redaction, access-limited and time-limited.
- [S] Record sealing and expungement orders.
- **Permissions:** `court.referral.review`, `court.calendar.manage`, `court.disposition.enter`, `court.discovery.issue`, `court.discovery.view`, `court.seal.order`.

### 7.21 Corrections bridge (M6)

- [M] Sentence handoff, time served, release date; inmate roster view for authorized users.

### 7.22 Personnel and roster (M6)

- [M] Officer profile: badge number, callsign, rank (read from Discord roles), division, hire date, bound character.
- [M] Hire, promote, demote, suspend, dismiss from FredPD, executed as Discord role changes through the gateway (section 4.2).
- [M] Shift log: on-duty and off-duty times, hours per week.
- [M] Equipment assignment: vehicle, radio, duty weapons (linked to the firearms registry).
- [S] Commendations and awards.
- [S] Scheduling.
- **Permissions:** `personnel.view`, `personnel.hire`, `personnel.promote`, `personnel.discipline`, `personnel.equipment.assign`.

### 7.23 Training, field training and certifications (S, M6)

- [S] Certifications (K9, air support, tactical, pursuit driving, FTO) with expiry. Certifications can be context conditions (only certified officers can sign on as K9 units).
- [S] Field training program: phases, daily observation reports, competency ratings, sign-off (based on ps-mdt v3 FTO).
- [S] Training records and course attendance.

### 7.24 Internal affairs, use of force and early intervention (S, M6)

- [S] Complaints from officers or civilians (public complaint form), intake, investigation, findings (sustained, not sustained, exonerated, unfounded), discipline.
- [S] Use-of-force reports with supervisor review.
- [S] Early-intervention alerts when thresholds are crossed (for example 3 use-of-force reports in 30 days), in the style of IAPro/BlueTeam.
- [S] Internal-affairs records live in the `internal_affairs` compartment.

### 7.25 Policies and SOPs (S, M6)

- [S] Policy library with versions, categories and required acknowledgement per role; tracking of who has read which version (PowerDMS style).

### 7.26 Communications (M4; internal chat M1)

- [M] **Internal police channel in the game chat (M1).** A police-only channel
  rendered in the standard FiveM chat box, so officers never have to open the
  MDT to talk. `/pd <message>` by default, command configurable.
  - Send needs `comms.pdchat.send`; a message is delivered only to sessions
    holding `comms.pdchat.view`. It is never broadcast to everyone
    (invariant 5) — the recipient list is computed on the server, per message.
  - The sender's callsign, name and agency are resolved **server-side** from the
    session and prefixed to the message; nothing about the author comes from the
    client (invariant 1).
  - Rate limited per session like any other route, and the body is length-capped
    and stripped of chat colour codes, so the channel cannot be used to spam or
    to forge another officer's prefix.
  - Stored append-only in `fpd_chat_messages` and readable in the MDT comms log
    with `comms.pdchat.view`, which is what makes it evidence rather than
    ephemeral noise.
  - Agency-scoped by default; a cross-agency channel needs `comms.pdchat.all`.
- [M] Unit-to-unit and dispatcher-to-unit messages.
- [M] Roll-call board: daily briefing with active BOLOs, warrants, officer-safety notes and announcements.
- [M] Notification center.
- [S] Department bulletins with categories and pinning.

### 7.27 Statistics (S, M6)

- [S] Crime counts by type, area and period; clearance rates; response times; officer activity; CompStat-style period comparisons.
- [S] CSV export behind a permission. No personal data in exports unless the permission allows it.

### 7.28 Printing and documents (S, M7)

- [S] Printable forms and PDF packets (report, case summary, warrant, citation, lab report, custody log) rendered by the gateway with letterhead, page numbers, document number and classification watermark.
- [S] "Print" creates an in-game paper document item whose metadata references the document ID; using it opens a read-only viewer. Access to the original stays controlled.

### 7.29 Civilian and legal access (S, M6)

- [S] Civilian mode: own citations, fines, court dates, complaint form, stolen-property report (based on ps-mdt v3 civilian mode).
- [S] Defense attorney mode: assigned discovery packages only.

### 7.30 Administration and system health (M1 basic, M7 full)

- [M] Agencies, divisions, branding, numbering formats.
- [M] Permission viewer and editor (Discord role → groups → keys), classification levels and compartments.
- [M] Code tables and penal code editor.
- [M] Audit log search and export.
- [S] Retention policies per data type (drafts, ALPR reads, query logs, wiretap sessions).
- [S] System health: gateway status, Discord sync age, DB latency, route timings, queue depths.
- [S] Feature flags and bridge status overview.
- [M] **Placement editor** (3.10): create, move, rebind and disable the world
  placements that open each module, in game, with `admin.placement.edit`.
- [M] **Discord role mapping** (4.3): map a Discord role ID to permission groups
  per agency from the MDT, with `admin.permissions.edit`. Every change is
  audited and takes effect on the next permission push, without a restart.

### 7.31 Agency motor pool (M1)

The garage officers actually use. Impound and tow stay with `p_policejob`
(3.11); this is the station motor pool only.

- [M] A motor pool is a **placement** (3.10) with a `ped` interaction, so its
  position and ped model are configured in game rather than in a config file.
- [M] Draw a vehicle from the agency's configured fleet. Each fleet entry names
  the model, the permission it needs and, optionally, a required certification
  (7.23), so a pursuit vehicle or a helicopter can be restricted without a
  separate garage.
- [M] Return a vehicle at any motor pool of the same agency.
- [M] Vehicles are society-owned through the `society` bridge, so the agency —
  not the officer — owns the fleet.
- [M] Every draw and return is logged in `fpd_motorpool_log` with the officer,
  the vehicle, the placement and the time. A vehicle out for a whole shift is
  visible to command, which is the point of logging it.
- [M] Drawing requires being on duty (a context condition, 4.3) and standing at
  the placement, verified server-side (3.10).
- [S] Fleet editor in Admin, so the vehicle list is configurable in game too.
- [S] Damage and fuel state carried over on return, where the framework exposes it.
- **Permissions:** `garage.vehicle.draw`, `garage.vehicle.return`,
  `garage.fleet.edit`.

---

## 8. Evidence, property and forensics

This replaces the noobsystems/evidences script with a server-authoritative design. Its mechanics are the gameplay reference; its code is not reused.

### 8.1 Principles

1. **Hidden truth.** Every character has hidden biometric identifiers (DNA and fingerprint) and every weapon a hidden barrel/tool-mark signature. These live only in server tables. No client ever receives them, including officers.
2. **Items carry references, not truth.** Evidence and weapon item metadata holds only an opaque reference (`fpd_ref`), an evidence number, description, packaging, seal state and case number.
3. **Leads, not answers.** A database hit is an investigative lead. Court-grade identification needs confirmation with a fresh reference sample.
4. **Time, quality and chance.** Lab work takes real (configurable) time. Sample age, weather, cleaning and contamination lower success rates.
5. **Nothing is perfectly clean.** Destroying evidence costs time and items and often leaves a different trace.
6. **Streams, not broadcasts.** Clients receive only render data (type, position, rotation, model) for evidence within streaming range, never owners or signatures.

### 8.2 Evidence types

| Type | Created when | Left on | Removed or reduced by | Collected as | Lab analysis | Based on |
|---|---|---|---|---|---|---|
| Latent fingerprints | Entering/exiting vehicles (per door), equipping weapons, using doors (ox_doorlock), safes, registers, ATMs, handled items | Vehicle doors, vehicles, weapons, doors, props | Wiping kit, rain (exterior), time. Gloves prevent prints but leave glove marks | Lift card | Comparison, fingerprint index search | evidences; evidences roadmap (building doors) |
| Blood | Damage above a threshold | Ground, vehicle seat, melee weapon, attacker's clothing | Cleaning chemicals (luminol still reveals it, with lower DNA yield), rain (outdoor), time | Swab | DNA | evidences |
| Saliva / touch DNA | Drinking, eating, smoking items, masks | Items, ground | Time, handling | Swab or bagged item | DNA (lower yield) | evidences roadmap |
| Casings | Every shot (sampled, section 12) | Ground, vehicle footwell | Picking up (takes time) | Casing envelope | Microstamp read, comparison, ballistics index | evidences |
| Bullets | Impact | Ground, networked entities (moves with the entity) | Digging out (takes time) | Bullet envelope | Comparison with test fire | evidences |
| Magazines | Reload (uses the game's dropped magazine position) | Ground, footwell | Picking up | Bag | Weapon type, prints | evidences |
| Gunshot residue | Firing | Shooter's hands and clothes | Washing at sinks and showers, time | GSR kit | GSR analysis | evidences |
| Footwear impressions | Walking on soft ground, snow, or through blood | Ground | Weather, time | Photo or cast | Comparison with footwear (appearance bridge) | community request on the evidences forum thread |
| Glove marks and fibers | Touching surfaces while wearing gloves | Same surfaces as prints | Wiping | Tape lift | Comparison with glove item/drawable | New |
| Drug residue | Using or handling drugs | Vehicle interior, hands | Cleaning, showering, time | Field test kit, swab | Substance identification | evidences roadmap |
| Tool marks and broken glass | Lockpicking, vehicle break-ins | Doors, vehicles | Repair | Photo, cast | Tool comparison | New |
| Digital | Seized phone item | Item | — | Phone evidence bag | Extraction through phone bridge (optional) | New |

Decay times, success rates and caps are configured per type.

Gunshot residue is the one row above with no position, so it is the one that is
not in the evidence grid: it is a state on the shooter, set by every shot,
decaying from the most recent one, cleared outright by washing (8.10) and taken
off a person with a swab. The swab has no route of its own: it is
`evidence.collect`, gated by `forensics.evidence.collect`, taking a `targetId`
— the swabbed person's server id, resolved and range-checked server-side —
where a trace would give it a `traceKey`. A swab is a collection, so it writes
the item, the owner row and the first link of the custody chain in the one
transaction every other collection uses (8.5, 8.6). What is
deliberately not modelled: residue does not transfer to a passenger, a seat or
anything handled afterwards, and it carries no weapon — a swab says this person
fired something, never what.

### 8.3 Generation pipeline

1. Client sensors detect the moment (door use, shot, damage, reload) and send a minimal route call: type plus context (for example the vehicle network ID and door index).
2. The server validates: the player's server-side position, entity existence and distance, the weapon from ox_inventory's server state, glove state from the appearance bridge, per-type rate limits.
3. Victim blood on an attacker's weapon is only created from the server-side `weaponDamageEvent` pair, never from a client claim.
4. The owner is always the source player's hidden identifier.
5. Evidence goes into a server-side spatial grid (and the database when linked to a scene). Nearby evidence of the same type and owner is merged.
6. Clients subscribed to a grid cell receive render data only.

### 8.4 Scene processing (M3)

- [M] Create a crime scene linked to a call or case; scene number; perimeter as a zone.
- [M] Scene entry log: every player entering the perimeter is logged with time; entering without protective equipment adds contamination risk (configurable).
- [M] Latent evidence is invisible until processed: fingerprint powder reveals prints on a surface, a forensic light or luminol reveals trace and cleaned blood. Visible evidence (casings, large blood pools, magazines) can be seen without tools.
- [M] Numbered evidence markers (props) placed on items; marker number recorded with the item.
- [M] Scene photography with the camera tool (screenshot-basic): position, time and marker numbers stored with each photo.
- [M] Collection with a progress action, packaging choice and automatic evidence number and barcode.
- [S] Scene tape and cones (props).
- [S] Scene release with a checklist before the perimeter is removed.
- **Permissions:** `forensics.scene.create`, `forensics.scene.release`, `forensics.evidence.collect`, `forensics.tools.use`.

### 8.5 Evidence items and packaging (M3)

- [M] Packaging types as items: evidence bag, envelope, swab box, lift card, firearm box, drug bag, phone bag, large-item tag.
- [M] Metadata (client-visible): evidence number, description, type, packaging, seal state, case number, marker number, `fpd_ref`.
- [M] Seals: opening a package breaks the seal (logged); resealing needs `evidence.item.reseal`.
- [M] Moving an evidence item is intercepted by the ox_inventory `swapItems` hook: allowed moves are recorded as custody transfers; moves outside approved flows (for example into a personal inventory without a check-out) are blocked and flagged.

### 8.6 Property room (M3)

- [M] Temporary lockers: the collecting officer deposits items; custody passes to the property room on acceptance.
- [M] Two-step intake at the property room terminal: scan, verify seal and description, assign a storage location (vault, shelf, bin as ox_inventory stashes), accept or reject with reason.
- [M] Storage stashes open only through FredPD permissions and the property room access point (enforced with the ox_inventory `openInventory` hook).
- [M] Chain of custody log for every transfer: from, to, reason, time, electronic signature.
- [M] Check-out and check-in (lab, court, investigator review) with due dates and overdue alerts.
- [M] Special handling: cash and drugs need two signatures at intake; drugs are weighed from item counts; firearms are linked to the registry and traced.
- [S] Inventory audits: expected contents from custody records compared with actual stash contents; discrepancies create a report and notify internal affairs.
- [S] Disposition: return to owner, destroy, retain, transfer to agency use. Requires case closure or prosecutor approval.
- [S] Found and safekeeping property (non-evidence) with owner notification.
- **Based on:** Axon Evidence, Tracker Products SAFE, BEAST, FileOnQ.
- **Permissions:** `evidence.item.view`, `evidence.item.intake`, `evidence.item.transfer`, `evidence.item.checkout`, `evidence.item.release`, `evidence.item.dispose`, `evidence.audit.run`.

### 8.7 Forensic lab (M3)

- [M] Lab request from a case: selected items, requested analyses, priority, justification.
- [M] Queue with priority, turnaround time (configurable real minutes per analysis and priority) and analyst assignment. Timers persist across restarts.
- [M] Analyses: DNA profiling (blood, saliva, touch), latent print comparison and index search, ballistics (microstamp, comparison with test fire), GSR, drug identification.
- [M] Results computed on the server from hidden truth, sample quality, age and contamination. Standard result language:
  - DNA: profile obtained, partial profile, mixture (number of contributors), no profile.
  - Comparisons: identification, exclusion, inconclusive, insufficient for comparison.
  - Database search: candidate match, confirmation required.
- [M] Interactive or automatic mode (configurable): analysts record method and observations, or the system completes the analysis when the timer ends.
- [S] Technical review by a second analyst before release.
- [S] Lab report PDF attached to the case.
- [S] Serial number restoration (section 8.9), toxicology and blood alcohol from medical samples, phone extraction.
- **Based on:** LIMS workflows (JusticeTrax LIMS-plus, STARLIMS); evidences laptop apps.
- **Permissions:** `lab.request.create`, `lab.queue.view`, `lab.analysis.perform`, `lab.analysis.review`, `lab.report.release`.

### 8.8 Forensic databases and identification (M3)

| Index | Contents | Real-world model | Swedish name (sv locale) |
|---|---|---|---|
| DNA — convicted | Profiles of convicted persons | CODIS offender index | DNA-registret |
| DNA — suspects | Reference samples from suspects and arrestees (policy-configurable) | CODIS arrestee index | Utredningsregistret |
| DNA — traces | Unidentified crime-scene profiles | CODIS forensic index | Spårregistret |
| Fingerprints | Ten-print cards from booking; unsolved latent file | NGI/AFIS | Fingeravtrycksregistret |
| Ballistics | Test fires and recovered casings/bullets | NIBIN | Vapen- och ammunitionsspår (fictional label) |

- [M] Which persons get indexed, and when profiles are removed (acquittal, time limits), is configurable policy.
- [M] New trace profiles are searched automatically against reference indexes; hits become leads on the case.
- [M] Confirmation workflow: a lead requires a new reference sample (booking or warrant) and a direct comparison before it counts as an identification.
- [S] Ballistic correlations link unsolved scenes that share a weapon.

### 8.9 Firearms tracing and serial restoration (S, M3)

- [S] Trace report from a recovered firearm: purchase, every transfer, theft reports, prior involvements.
- [S] Filed serials become "obliterated". Restoration success depends on the tool used and filing depth; a restored serial re-links the weapon to the registry.

### 8.10 Destroying evidence (M3)

- [M] Wiping kit for surfaces and weapons, cleaning chemicals for blood, washing for GSR, picking up casings and magazines. Each takes a timed action and consumes items.
- [M] Cleaning leaves detectable traces (luminol) with reduced DNA yield.
- [M] Available to every player through ox_target, subject only to item and context rules. Police-only restrictions must never block criminal gameplay (a bug in the reference script).
- [S] Burning a vehicle destroys its interior evidence.

### 8.11 Anti-metagaming

- [M] No evidence owners, signatures or observer identities in client payloads, state bags or broadcasts.
- [M] Clients only learn about evidence inside their streaming range.
- [M] Lab results and identities only reach sessions with the matching permissions and compartments.

---

## 9. Surveillance and interception (M5)

- [M] Every surveillance measure needs an active surveillance warrant (section 7.12) with scope (person, phone number, vehicle, location), method and expiry. Export `HasActiveWarrant(target, 'surveillance', method)`.
- [M] Methods:
  - **Phone interception:** live listening to calls of a warranted number, with call metadata logging.
  - **Radio monitoring:** listening to a radio channel, with a configurable blocklist (police, EMS).
  - **Listening devices:** placed items; presence detection is computed server-side from positions, scaled by the target's current voice range and limited to the same interior.
  - **Vehicle trackers:** item attached to a vehicle; position pings every N seconds to authorized sessions; battery life.
- [M] Sessions (start, end, observer, target, warrant, method) are written by the server. Observers write a product log with minimization notes.
- [M] Voice routing through pma-voice. pma-voice clears voice target 1 when a player releases the radio key or a call changes, so observers are re-applied after those events.
- [M] Counter-surveillance: a sweeper item detects listening devices and trackers nearby.
- [M] Retention per configuration; no broadcasts of sessions or device lists.
- [S] Research spike: evaluate listening through pma-voice grid channels for listening devices, so targets' clients are not told who is listening (with voice targets, the target client must know the observer's server ID).
- **Based on:** the wiretap app in noobsystems/evidences, re-implemented with warrant gating and server-authored logs.
- **Permissions:** `surv.phone.intercept`, `surv.radio.monitor`, `surv.device.deploy`, `surv.device.listen`, `surv.tracker.deploy`, `surv.tracker.view`, `surv.log.view`.

---

## 10. PD-Span integration (intelligence)

### 10.1 Status

The inventory (10.5) is done: `docs/pd-span-inventory.md`. It found that PD-Span is a Next.js application on Supabase rather than a FiveM resource, so option 1 of 10.3 was taken in its reframed form — **the data model is ported into the monorepo as the `intel` module and the interface is rebuilt**, rather than a resource being merged or a bridge being written.

The register now lives in the server's own MariaDB (the `fpd_intel_*` tables in migration 0001) and persists there. The existing PD-Span data is deliberately **not** migrated: the module starts empty and the register is built up in game.

That makes the bridge contract in 10.4 unnecessary — there is no second system to bridge to. It is kept below as a record of what was considered.

### 10.2 What "directly integrated" means

- One sign-on and one permission system: PD-Span uses FredPD sessions and Discord-derived permissions; its own permission logic is removed.
- Shared entities: PD-Span persons, vehicles, phones, addresses and organisations reference FredPD's master records by ID.
- One interface: PD-Span screens render inside the FredPD shell as the **Intel** module.
- Cross-links: an "Intelligence (restricted)" tab on persons, vehicles and addresses; "Start surveillance log" from a record.
- One audit log and one classification and compartment model.

### 10.3 Integration options (ranked)

1. **Merge PD-Span into the monorepo as the `intel` module** (preferred if PD-Span is a FiveM resource you own). Cleanest result; requires porting its UI into the FredPD web app.
2. **Keep PD-Span as its own resource and integrate through the bridge contract** (10.4), with its UI embedded as a FredPD module. Less migration work, two codebases to maintain.
3. **Database-level integration only** (views and shared IDs). Last resort; weakest access control.

### 10.4 Bridge contract (`server/bridges/span/*.lua`)

| Function | Purpose |
|---|---|
| `getEntitySummary(session, entityType, entityId)` | Sanitized intel summary for a FredPD record, filtered by clearance and compartments |
| `listSurveillanceLogs(session, filter)` | Logs visible to the session |
| `createSurveillanceLog(session, input)` | Mandatory fields enforced (10.6) |
| `createIntelReport(session, input)` | Graded report |
| `linkEntities(session, a, b, relation)` | Link-analysis edges |
| `onRecordEvent(event)` | FredPD events PD-Span reacts to (arrest booked, warrant issued, lab result) |
| `migrateIds()` | One-time mapping of PD-Span entity IDs to FredPD master IDs |

### 10.5 Inventory task for Claude Code

1. Place PD-Span's source under `vendor/pd-span/` (or as a git submodule).
2. Produce `docs/pd-span-inventory.md`:
   - fxmanifest and dependencies;
   - database tables and their mapping to FredPD entities;
   - exports, events and callbacks;
   - UI technology;
   - permission logic to replace;
   - data migration plan;
   - a security review against section 0 and section 11.
3. Recommend option 1, 2 or 3 with effort estimates, then implement the bridge contract.

### 10.6 Intelligence features (target)

- [M] Intelligence reports graded for source reliability (A–F) and information credibility (1–6), with handling codes that restrict dissemination.
- [M] Surveillance logs cannot be saved without: officer(s), target, grounds for surveillance, start time, end time and observations. This matches the RUE unit guidelines on surveillance and source handling (grounds documented before action, start and end times, traceability).
- [M] Source register in the `sources` compartment:
  - pseudonymized source IDs, with the true identity visible only to the controller role;
  - handler assignment, with every handler change logged;
  - contact log.
- [M] Operations that need command approval (for example a raid based on intelligence) go through an approval workflow.
- [S] Taskings, watchlists, organisation (gang) profiles, link-analysis graph of persons, vehicles, phones, addresses and organisations.
- [S] Sanitized patrol flags ("Caution: armed") that never reveal the underlying intelligence or source.
- [S] Review reminders for records not reviewed within a set period; retention rules.
- **Permissions:** `intel.module.open`, `intel.report.create`, `intel.report.view`, `intel.surveillance.log`, `intel.source.view`, `intel.source.manage`, `intel.source.identity.view`, `intel.operation.approve`.

---

## 11. Security specification

### 11.1 Threat model

| Threat | Example | Controls |
|---|---|---|
| Executor-triggered events | Player calls routes directly with forged input | Route wrapper, schemas, server-derived identity, rate limits |
| Corrupt or curious officer | Reads restricted files, fabricates evidence, forges audit fields | Record access checks, server-computed results, append-only audit, break-glass alerts, early intervention |
| Metagaming | Reading state bags or events to find shooters, evidence owners or wiretaps | Streaming render data only, no owners on clients, no broadcasts |
| Data exfiltration | Mass export of persons or intel | Export permissions, row limits, audit, redaction |
| IP grabbing | Markdown or image URLs pointing to an attacker's server | No markdown in item descriptions from user input, media only via gateway, CSP |
| Denial of service | Event floods, huge payloads, evidence spam | Rate limits, payload size caps, evidence caps and merging, latent events for bulk data |
| Item duplication | Place/pickup flows that mint items | Server-side item checks, affected-row checks, transactions |
| Stale permissions | Discord outage keeps revoked access alive | Snapshot age limits (4.2), live revocation |
| Secret leakage | Bot token or HMAC secret in client files | `config/server.lua` (server_scripts, never `files {}`), `set` convars, gateway env; CI secret scanning |
| Server ID reuse | New player inherits a dropped player's session | Sessions destroyed on drop |

### 11.2 Required controls

- Every route: permission, context, schema with max lengths, rate limit, audit.
- Every service read: record access check (4.5) before data leaves the server.
- Every write: transaction where more than one table changes; check affected rows.
- Every item-related action: server-side item presence and removal before the effect.
- Every media URL: signed, expiring, access-checked at issue time.
- The NUI: Content Security Policy meta tag, no `innerHTML`, no generic "call any callback" proxy.
- The gateway: HMAC on every FXServer call, loopback only, request size limits, dependency audit in CI.
- The database: a dedicated FredPD user; the audit table has no UPDATE or DELETE grant.

### 11.3 Banned patterns (from the noobsystems/evidences review)

- A generic net event that calls any method with client arguments.
- Client-chosen event targets (for example a client-supplied player ID used as `TriggerClientEvent` target).
- Effects before item checks (placing devices or laptops without removing the item server-side).
- Treating "query succeeded" as "row changed".
- Config files with secrets listed in `files {}`.
- User text rendered as markdown or HTML without sanitizing.
- Audit rows written from client-supplied fields, or only when the client chooses to call.
- Trusting stash or inventory IDs from the client without ownership checks.
- Broadcasting objects that contain observer or participant lists.
- Accidental globals (enforced by luacheck in CI).

### 11.4 Privacy (GDPR)

FredPD links gameplay records to real players (Discord ID, FiveM license), so the server operator is processing personal data.

- Collect only what the features need; document it in the server's privacy notice.
- Retention periods per data type (section 7.30), enforced by the gateway scheduler.
- A documented procedure to export or delete a player's data on request.
- Access to real-player identifiers (Discord ID, license) is limited to administrators and always audited.

### 11.5 Security test checklist (per route)

Unauthenticated call, missing permission, failed context condition, invalid types, oversized input, unknown keys, rate-limit breach, access to a record in another agency, restricted record without clearance, stale permission snapshot. Each case has an automated test (section 15).

---

## 12. Performance specification

### 12.1 Budgets (acceptance criteria)

| Metric | Budget |
|---|---|
| Keypress to usable MDT | < 100 ms (UI preloaded, cached data shown immediately) |
| Route handling time, p95 | < 50 ms server-side |
| Query (person or plate) end-to-end, p95 | < 150 ms |
| Client resmon while FredPD is closed | 0.00 ms |
| Client resmon, MDT open and idle | < 0.05 ms |
| Initial NUI bundle | ≤ 250 KB gzipped; editor, map and charts load on demand |
| Evidence streaming per client | ≤ 1 update per second per grid cell |
| Server tick cost of forensics at 200 players | < 1 ms average |

### 12.2 Techniques

- **NUI:** preloaded and hidden at resource start; one `bootstrap` call on open (session, unit, counters); per-tab data loading; code-split heavy views; TanStack Query stale-while-revalidate cache; virtualized grids; no blur or animation costs. All resources' NUI pages share one browser process, so FredPD must stay light.
- **Network:** delta pushes to subscribed sessions only; latent events for bulk data; payload size caps; casing and blood generation sampled and merged (for example one casing per N shots within a radius).
- **Server:** in-memory caches for code tables, permission sets, active warrant and BOLO flags, unit board (invalidated on write); no per-tick loops for idle modules; spatial grid for evidence.
- **Database:**
  - a person search index table with normalized names and SOUNDEX, maintained from framework events (no JSON scans on `players`);
  - FULLTEXT on narratives;
  - keyset pagination;
  - prepared statements for hot queries;
  - one JOIN or parallel queries per screen.
- **Media:** WebP thumbnails, lazy-loaded images, long cache headers.

### 12.3 Measurement

- Route timing logged per route; a slow-route report in Admin.
- A load-test harness in `tools/` that simulates officers calling routes and players generating evidence, run against staging before each milestone closes.
- MariaDB slow query log enabled on staging.

---

## 13. Data model

### 13.1 Conventions

- Table prefix `fpd_`. Primary keys `BIGINT UNSIGNED AUTO_INCREMENT`. Human-readable numbers in separate unique columns.
- Common columns: `agency_id`, `created_at`, `created_by`, `updated_at`, `updated_by`, `version` (optimistic locking), `classification`, `deleted_at` (soft delete where retention requires).
- Compartments in a join table (`fpd_record_compartments`), explicit grants in `fpd_record_grants`.
- Timestamps `DATETIME(3)` in UTC. `utf8mb4_unicode_ci`.
- Numbers generated from `fpd_counters` inside a transaction with a row lock.

### 13.2 Tables by area

| Area | Tables |
|---|---|
| Core | `fpd_migrations`, `fpd_settings`, `fpd_agencies`, `fpd_divisions`, `fpd_counters`, `fpd_audit_log`, `fpd_query_log`, `fpd_outbox`, `fpd_i18n_overrides`, `fpd_placements` |
| Access | `fpd_discord_members`, `fpd_role_map`, `fpd_permission_groups`, `fpd_group_permissions`, `fpd_classifications`, `fpd_compartments`, `fpd_record_compartments`, `fpd_record_grants`, `fpd_breakglass` |
| Personnel | `fpd_officers`, `fpd_shift_log`, `fpd_certifications`, `fpd_training`, `fpd_equipment`, `fpd_commendations`, `fpd_fto_*`, `fpd_ia_cases`, `fpd_uof_reports`, `fpd_policies`, `fpd_policy_acks` |
| Records | `fpd_persons`, `fpd_person_index`, `fpd_person_aliases`, `fpd_person_descriptors`, `fpd_person_photos`, `fpd_person_cautions`, `fpd_addresses`, `fpd_person_addresses`, `fpd_vehicles`, `fpd_vehicle_flags`, `fpd_firearms`, `fpd_firearm_events`, `fpd_notes`, `fpd_attachments` |
| Reports and cases | `fpd_reports`, `fpd_report_versions`, `fpd_report_persons`, `fpd_report_offences`, `fpd_report_property`, `fpd_report_vehicles`, `fpd_cases`, `fpd_case_links`, `fpd_case_tasks` |
| Enforcement | `fpd_arrests`, `fpd_arrest_charges`, `fpd_bookings`, `fpd_citations`, `fpd_warrants`, `fpd_warrant_events`, `fpd_bolos`, `fpd_fi_cards`, `fpd_stops`, `fpd_impounds` |
| Legal | `fpd_penal_code`, `fpd_penal_code_versions`, `fpd_court_referrals`, `fpd_hearings`, `fpd_dispositions`, `fpd_discovery_packages` |
| Dispatch | `fpd_calls`, `fpd_call_units`, `fpd_call_events`, `fpd_units`, `fpd_unit_status_log`, `fpd_beats`, `fpd_premise_hazards`, `fpd_alpr_reads`, `fpd_messages`, `fpd_bulletins`, `fpd_chat_messages` |
| Motor pool | `fpd_fleet`, `fpd_motorpool_log` |
| Forensics | `fpd_bio_identity` (hidden), `fpd_weapon_signatures` (hidden), `fpd_scenes`, `fpd_scene_log`, `fpd_scene_photos`, `fpd_evidence_world`, `fpd_evidence_items`, `fpd_custody`, `fpd_storage_locations`, `fpd_audits`, `fpd_lab_requests`, `fpd_lab_results`, `fpd_dna_index`, `fpd_print_index`, `fpd_ballistic_index`, `fpd_leads` |
| Surveillance | `fpd_surv_sessions`, `fpd_surv_devices`, `fpd_surv_product_log` |
| Intelligence | `fpd_intel_persons`, `fpd_intel_orgs`, `fpd_intel_memberships`, `fpd_intel_associates`, `fpd_intel_notes`, `fpd_intel_note_tags`, `fpd_intel_vehicles`, `fpd_intel_cases`, `fpd_intel_case_links`, `fpd_intel_evidence` |
| Media | `fpd_media` (hash, type, size, owner record, access control reference) |

### 13.3 Retention jobs

The gateway scheduler runs retention per data type (drafts, ALPR reads, query logs, surveillance sessions, closed scenes), writes a summary to the audit log and never touches the audit log itself.

---

## 14. Integration API for other resources

All events are server-local (`TriggerEvent`), never network events.

**Server exports**

| Export | Purpose |
|---|---|
| `IsWanted(citizenid)` | Active arrest warrant exists |
| `HasSearchWarrant(targetType, targetId)` | Valid search warrant for a person, vehicle or address (raid and door scripts) |
| `HasActiveWarrant(target, kind, method?)` | Generic warrant check (surveillance and others) |
| `GetPersonCautions(citizenid)` | Sanitized cautions for other scripts |
| `RegisterFirearm(data)` / `ReportFirearmStolen(serial)` | Gun shops, crafting, theft scripts |
| `CreateCall(data)` | Alerts from robberies, shots fired, alarms |
| `AddWorldEvidence(data)` | Server-side evidence from other scripts (for example prints on a robbed register) |
| `IsOnDuty(src)` / `HasPermission(src, key)` | Permission checks for other police scripts |
| `OpenMDT(src, accessPoint?)` | Open FredPD from other interactions |

**Server events**

`fredpd:warrantIssued`, `fredpd:warrantServed`, `fredpd:arrestBooked`, `fredpd:citationIssued`, `fredpd:evidenceCollected`, `fredpd:custodyTransferred`, `fredpd:labResultReleased`, `fredpd:callCreated`, `fredpd:unitStatusChanged`, `fredpd:emergency`, `fredpd:permissionsChanged`.

**Integration examples**
- ox_doorlock raid doors only open for officers when `HasSearchWarrant('address', id)` is true.
- Store robbery: `CreateCall` plus `AddWorldEvidence` for prints on the register.
- Gun shop purchase: `RegisterFirearm` through the `buyItem` hook.
- Jail resource receives sentences from `fredpd:arrestBooked` and court dispositions.

---

## 15. Quality, testing and CI

- **Unit tests (busted):** every `service.lua` (pure logic, no natives): permissions, access rules, sentencing, lab outcomes, custody rules, numbering.
- **Route contract tests:** a Lua harness that invokes route definitions with fake sessions and runs the checklist in 11.5.
- **Gateway tests (Vitest):** role sync, HMAC, media tokens, retention jobs.
- **UI tests (Playwright):** the web app runs in a browser against a mock NUI bridge with fixtures. Screenshot tests for key screens in day and night themes, English and Swedish.
- **Static checks:** luacheck (no accidental globals), lua-language-server diagnostics, ESLint (including the no-literal-strings rule), svelte-check, tsc, `pnpm i18n:check`, secret scanning, dependency audit.
- **Migrations:** CI applies all migrations to an empty database and to a copy of the previous release's schema.
- **CI workflows:** `ci.yml` on pull requests; `release.yml` on tags (build web, bundle resources, attach artifacts).

**Definition of done (every issue)**
1. Acceptance criteria from this spec met.
2. Section 0 invariants respected.
3. Tests added and passing; all static checks green.
4. `en` and `sv` keys complete.
5. Permissions added to Appendix B and the seed file.
6. Docs or ADR updated if behavior or decisions changed.

---

## 16. Deployment and operations

- **Host:** FXServer (txAdmin), MariaDB, gateway and Caddy on the same dedicated machine. Gateway runs under systemd with automatic restart.
- **Environments:** local development, staging (separate FXServer instance and database), production.
- **Backups:** nightly database dump and media sync to off-site storage; monthly restore drill.
- **Monitoring:** gateway health endpoint; route timing and error rates; Discord sync age; alerts to a staff channel without sensitive data.
- **Releases:** semantic versioning, changelog, database backup before migrations, migrations run on start and refuse to run on an unexpected schema.

---

## 17. Roadmap and GitHub setup

### 17.1 Milestones

Estimates assume one developer working with Claude Code.

| Milestone | Scope | Estimate | Exit criteria |
|---|---|---|---|
| M0 Repository and tooling | Monorepo, CI, lint and test tooling, CLAUDE.md, ADRs, issue templates, empty resources, mock NUI bridge | 8–12 h | `pnpm build` output starts on staging without errors; CI green |
| M1 Platform core | Migrations, route layer, schema codegen, audit, sessions, Discord gateway and role sync, permissions and context conditions, access points, NUI shell and themes, i18n with `sv` and custom overlay, branding and media, permission viewer, unit sign-on and status | 40–60 h | An officer opens FredPD in under 100 ms, sees only permitted modules, loses access live when a role is removed; Swedish works end to end |
| M2 Records core | Person index and search, persons, vehicles, firearms registry, hot-file hits, query log, penal code and sentencing, reports with approval, arrests, warrants with judge review, BOLOs, basic cases, attachments, record-level access control | 60–80 h | Query → hit → arrest → report → approval works; warrant flow works; restricted records are enforced in search, views and exports |
| M3 Evidence and forensics | Hidden identity and signatures, generation pipeline, evidence types (prints, blood, casings, bullets, magazines, GSR first), destruction, scenes, packaging, custody enforcement, property room, lab, databases, leads and confirmation, test fires | 60–80 h | A shooting scene can be processed through property room and lab to a confirmed identification, with no forensic truth reaching clients |
| M4 Dispatch and map | Calls, `CreateCall`, unit board, recommendations, emergency button, timers, map and AVL, beats, premise hazards, messages, roll call, ALPR | 40–60 h | A dispatcher runs a P1 call end to end, including report creation |
| M5 Intelligence and surveillance | PD-Span inventory and integration, intel module, graded reports, surveillance logs, source register, approvals, surveillance warrants, interception methods, sweeper | 30–50 h (depends on PD-Span) | Warrant-gated surveillance with server-written logs; PD-Span data inside FredPD under compartments |
| M6 Personnel, court, remaining records | Roster with Discord role actions, shift log, equipment, certifications, FTO, IA and use of force, early intervention, policies, court, booking, citations, impound, field interviews and stops, statistics, civilian and attorney modes | 50–70 h | A full department and court lifecycle runs in FredPD |
| M7 Printing, portal, hardening, launch | PDF and paper documents, web portal, retention jobs, system health, load tests, security review, documentation, release pipeline | 30–40 h | Budgets met under load on staging; security checklist passed; v1.0.0 tagged |

Total: roughly 320–450 hours.

### 17.2 Initial issues per milestone

**M0**
- Create pnpm monorepo per 3.1
- Add luacheck, lua-language-server config, ESLint, svelte-check, tsc, busted, Vitest, Playwright
- Add `ci.yml` and `release.yml`
- Add CLAUDE.md files and `.claude/` agents, skills and hooks (section 18)
- Write ADR-001 (Lua server), ADR-002 (Svelte 5 NUI), ADR-003 (gateway service), ADR-004 (Discord as permission source)
- Scaffold `fredpd`, `fredpd_forensics`, `fredpd_surveillance`, `fredpd_assets`
- Build the mock NUI bridge and fixture system for browser development
- Import PD-Span source into `vendor/pd-span/` and run the inventory task (10.5)

**M1**
- Migration runner and `fpd_migrations`
- Schema package and codegen (TypeScript types and Lua validator tables)
- Route wrapper with rate limits and error envelope
- Audit log service (append-only)
- Session service and bound-character check
- Gateway: Fastify skeleton, HMAC, outbox
- Gateway: Discord bot, member snapshot, change push
- Permission groups, role map, seed, evaluator, context conditions
- Stale-permission policy
- Access points: MDC, tablet, station and specialist terminals
- NUI shell: title bar, module rail, command line, tabs, context panel, status bar
- Day and night themes with design tokens
- Locale loader, custom overlay, `sv.json`, `i18n:check`
- Agency branding and logo upload through the media service
- Admin: permission viewer
- Unit sign-on and status keys

**M2**
- Person search index with SOUNDEX, and search UI
- Person record (identity, descriptors, photos, cautions, licences, involvements)
- Vehicle record and flags
- Firearms registry and `buyItem` registration hook
- Hot-file checks and hit confirmation banner
- Query logging and reason prompts
- Penal code tables, versions, sentencing calculator
- Report types, sections, templates, drafts
- Report approval workflow, locking, supplements, versions, signatures
- Arrest records
- Warrant request, judge review, lifecycle, exports
- BOLOs with auto-resolve
- Basic cases and linking
- Attachments with signed URLs
- Record access control: classifications, compartments, grants, restricted stubs, break-glass, field redaction

**M3 to M7**: create issues from each module's MUST items first, then SHOULD items, one issue per bullet group, each linking its spec section.

### 17.3 Repository conventions

- **Labels:** `module:core`, `module:rms`, `module:cad`, `module:evidence`, `module:lab`, `module:intel`, `module:surv`, `module:court`, `module:personnel`, `module:admin`, `module:ui`, `module:i18n`, `module:gateway`; `type:feature`, `type:bug`, `type:security`, `type:perf`, `type:docs`, `type:chore`; `priority:p0`–`priority:p3`; `status:blocked`, `status:needs-spec`.
- **Issue template:** user story, spec section link, acceptance criteria, permissions, locale keys, test plan.
- **Branches:** `main` protected; pull requests require green CI; squash merge; conventional commit messages.
- **Project board:** columns Backlog, Ready, In progress, Review, Done; milestones as iterations.

---

## 18. Working with Claude Code

### 18.1 Files Claude Code reads

- `CLAUDE.md` in the repo root (provided with this spec): short rules and pointers.
- Nested `CLAUDE.md` files in `web/`, `gateway/` and `resources/[fredpd]/fredpd/` for area-specific conventions. Claude Code loads files in subdirectories when it works there.
- Keep every CLAUDE.md short. Claude Code's documentation notes that files over 200 lines consume more context and may reduce adherence. Put detail in this spec and reference section numbers.
- CLAUDE.md guides behavior but does not enforce it. Use hooks for hard rules.

### 18.2 `.claude/` setup

- **Subagents** (`.claude/agents/`), each reading its spec sections and reviewing the current diff:
  - `security-reviewer`: sections 0 and 11;
  - `ui-reviewer`: section 6;
  - `i18n-reviewer`: section 5;
  - `perf-reviewer`: section 12.
- **Skills** (`.claude/skills/`): `new-route`, `new-migration`, `new-page`, `add-locale-keys`, `new-bridge`. Each encodes the file layout and checklist for that task.
- **Hooks** (`.claude/settings.json`):
  - after edits, run luacheck or ESLint on the changed files;
  - before edits, block changes to existing files in `database/migrations/` and to environment files.

### 18.3 Workflow per issue

1. Start a fresh session for each issue.
2. Plan mode: ask Claude Code to read section 0 plus the issue's spec section and propose a plan with the files it will touch.
3. Implement in small commits.
4. Run tests and all static checks.
5. Run the `security-reviewer` subagent, plus `ui-reviewer` for UI work.
6. Update docs or add an ADR if anything changed.
7. Open a pull request that links the issue and spec section.

### 18.4 Starter prompts

- **M0:** "Read docs/FredPD.md sections 0, 3 and 15. Set up the monorepo exactly as described in 3.1 with the tooling from 3.3 and 15, the ci.yml workflow, and empty resources that start without errors. Propose the plan first."
- **Route layer:** "Implement server/core/route.lua according to sections 0 and 3.5, with busted tests covering every case in 11.5. Plan first and list the files you will create."
- **PD-Span inventory:** "Read vendor/pd-span completely and write docs/pd-span-inventory.md following section 10.5. Do not change any code."
- **Design tokens:** "Implement the design tokens and application shell from section 6 in web/, with day and night themes and Playwright screenshot tests. Follow 6.6 strictly."

---

## 19. Open decisions and inputs needed

| Decision or input | Why it matters | Needed by |
|---|---|---|
| ~~What PD-Span is technically and where its source lives~~ | **Resolved.** A live Next.js app on Supabase, not a FiveM resource. See `docs/pd-span-inventory.md` | M0 — done |
| Agencies at launch (names, logos, colors) | Branding, numbering, sharing rules | M1 |
| Discord guild ID and role IDs (ranks, units, compartments, DOJ) | Permission seed | M1 |
| Procedure style: US-style workflows with Swedish text, or Swedish-style procedure (gripande, anhållande, häktning, prosecutor-led förundersökning) | Report, warrant and court workflows | M2 |
| UI framework confirmation (Svelte 5 or React) | Locks in the web stack | End of M1 |
| Phone, jail, billing, housing, appearance resources | Bridges | M2–M4 |
| ~~Garage resource~~ | **Resolved.** FredPD owns the agency motor pool (7.31); impound stays with `p_policejob` | M1 — decided |
| Dispatch alerts: built-in only or a ps-dispatch adapter | CAD scope | M4 |
| Map tile source | Map module | M4 |
| Retention periods per data type | Privacy and performance | M3 |
| Lab turnaround times and success rates | Game balance | M3 |
| Which evidence persists across restarts | Database load, realism | M3 |
| Web portal at launch or later | M7 scope | M6 |

---

## Appendix A — Terminology (English → Swedish)

Swedish legal procedure differs from US procedure. Where no direct equivalent exists, the nearest Swedish concept is used; review before release.

| English | Svenska | Note |
|---|---|---|
| Officer | Polis | Rank-neutral |
| Trainee | Aspirant | |
| Field training officer | Handledare | |
| Field supervisor | Yttre befäl | |
| Unit | Enhet | |
| Callsign | Anropssignal | |
| Dispatch center | Ledningscentral | Regional: RLC |
| Call (incident) | Händelse | |
| Priority | Prioritet | Prio 1–4 |
| Available / En route / On scene | Tillgänglig / På väg / På plats | |
| Emergency button | Nödlarm | |
| Shift / Briefing | Pass / Passgenomgång | |
| Report (offence) | Anmälan | Brottsanmälan |
| Supplemental report | Tilläggsuppgift | |
| Narrative | Händelseförlopp | |
| Case | Ärende | |
| Investigation / Preliminary investigation | Utredning / Förundersökning (FU) | |
| Investigator | Utredare | |
| Suspect | Misstänkt | |
| Victim | Målsägande | |
| Witness | Vittne | |
| Reporting party | Anmälare | |
| Arrest (apprehension) | Gripande | |
| Detention (prosecutor decision) | Anhållande | |
| Remand (court decision) | Häktning | |
| Booking | Inskrivning i arrest | |
| Physical description | Signalement | |
| Criminal record | Belastningsregister | |
| Suspicion register | Misstankeregister | |
| Wanted | Efterlyst | |
| Arrest warrant | Efterlysning (anhållen i sin frånvaro) | No direct equivalent |
| Search warrant | Beslut om husrannsakan | |
| BOLO | Spaningsuppdrag | |
| Seizure / Seized property | Beslag | |
| Evidence | Bevis | |
| Property room | Beslagsförråd | |
| Chain of custody | Beviskedja | |
| Crime scene | Brottsplats | |
| Crime scene technician | Kriminaltekniker | |
| Forensic lab | Forensiskt laboratorium | |
| Fingerprint | Fingeravtryck | |
| Fingerprint register | Fingeravtrycksregistret | |
| DNA indexes | DNA-registret, utredningsregistret, spårregistret | See 8.8 |
| Gunshot residue | Skottrester | |
| Casing / Bullet / Magazine | Hylsa / Kula / Magasin | |
| Firearm register | Vapenregistret | |
| Serial number (firearm) | Tillverkningsnummer | |
| Vehicle register | Vägtrafikregistret | |
| Registration number | Registreringsnummer | |
| Driving licence | Körkort | |
| Citation | Ordningsbot | Summary penalty: strafföreläggande |
| Fine | Böter | |
| Impound | Omhändertagande av fordon | |
| Intelligence / Intelligence report | Underrättelser / Underrättelserapport | |
| Surveillance | Spaning | |
| Source / Handler | Källa / Källhanterare | |
| Phone interception | Hemlig avlyssning av elektronisk kommunikation (HAK) | |
| Listening device | Hemlig rumsavlyssning (HRA) | |
| Tracker | Spårsändare | |
| Prosecutor / Judge / District court | Åklagare / Domare / Tingsrätt | |
| Defense attorney | Försvarare | |
| Internal affairs | Särskilda utredningar | |
| Use of force | Våldsanvändning | |
| Classification: open, internal, restricted, confidential, secret | Öppen, Intern, Begränsat hemlig, Konfidentiell, Hemlig | Swedish security classes |

## Appendix B — Permission catalog (initial)

| Area | Keys |
|---|---|
| Pages | `page.query`, `page.dispatch`, `page.records`, `page.evidence`, `page.lab`, `page.intel`, `page.court`, `page.personnel`, `page.stats`, `page.admin`, `page.comms` |
| Queries | `query.person.run`, `query.vehicle.run`, `query.firearm.run`, `query.phone.run`, `query.address.run`, `query.log.view` |
| Records | `rms.person.view`, `rms.person.edit`, `rms.person.photo.upload`, `rms.person.caution.edit`, `rms.vehicle.view`, `rms.vehicle.edit`, `rms.vehicle.flag`, `rms.firearm.view`, `rms.firearm.edit`, `rms.firearm.trace`, `rms.location.view`, `rms.location.hazard.edit` |
| Reports | `rms.report.create`, `rms.report.edit.own`, `rms.report.submit`, `rms.report.approve`, `rms.report.return`, `rms.report.void`, `rms.report.view.<type>` |
| Enforcement | `rms.arrest.create`, `rms.citation.issue`, `rms.citation.void`, `rms.bolo.create`, `rms.bolo.cancel`, `rms.bolo.view`, `rms.fi.create`, `rms.stops.create`, `rms.impound.create`, `rms.impound.release`, `rms.impound.hold.release`, `rms.warrant.serve` |
| Investigations | `inv.case.create`, `inv.case.view`, `inv.case.edit`, `inv.case.assign`, `inv.case.close` |
| Booking | `booking.create`, `booking.biometrics.capture`, `booking.release` |
| Court | `court.warrant.request`, `court.warrant.review`, `court.warrant.recall`, `court.referral.review`, `court.calendar.manage`, `court.disposition.enter`, `court.discovery.issue`, `court.discovery.view`, `court.seal.order`, `court.citation.adjudicate`, `court.sentence.calculate` |
| Dispatch | `cad.call.create`, `cad.call.dispatch`, `cad.call.self_assign`, `cad.call.clear`, `cad.unit.manage`, `cad.broadcast`, `cad.console.open`, `alpr.read.view`, `alpr.hotlist.manage` |
| Forensics | `forensics.scene.create`, `forensics.scene.release`, `forensics.evidence.collect`, `forensics.tools.use` |
| Property room | `evidence.item.view`, `evidence.item.intake`, `evidence.item.transfer`, `evidence.item.checkout`, `evidence.item.release`, `evidence.item.dispose`, `evidence.item.reseal`, `evidence.audit.run` |
| Lab | `lab.request.create`, `lab.queue.view`, `lab.analysis.perform`, `lab.analysis.review`, `lab.report.release` |
| Surveillance | `surv.phone.intercept`, `surv.radio.monitor`, `surv.device.deploy`, `surv.device.listen`, `surv.tracker.deploy`, `surv.tracker.view`, `surv.log.view` |
| Intelligence | `intel.module.open`, `intel.report.create`, `intel.report.view`, `intel.report.edit`, `intel.person.view`, `intel.person.edit`, `intel.person.merge`, `intel.org.view`, `intel.org.edit`, `intel.case.view`, `intel.case.edit`, `intel.evidence.add`, `intel.record.delete`, `intel.surveillance.log`, `intel.source.view`, `intel.source.manage`, `intel.source.identity.view`, `intel.operation.approve` |
| Personnel | `personnel.view`, `personnel.hire`, `personnel.promote`, `personnel.discipline`, `personnel.equipment.assign`, `ia.case.view`, `ia.case.manage`, `uof.review`, `policy.manage`, `policy.ack` |
| Communications | `comms.message.send`, `comms.bulletin.post`, `comms.pdchat.send`, `comms.pdchat.view`, `comms.pdchat.all` |
| Motor pool | `garage.vehicle.draw`, `garage.vehicle.return`, `garage.fleet.edit` |
| Statistics | `stats.view`, `stats.export` |
| Administration | `admin.permissions.edit`, `admin.groups.edit`, `admin.penalcode.edit`, `admin.codetables.edit`, `admin.branding.edit`, `admin.audit.view`, `admin.retention.edit`, `admin.health.view`, `admin.placement.edit` |
| Access | `records.breakglass`, `clearance.<level>`, `compartment.<name>`, `fields.mental_health.view`, `fields.victim_address.view` |

## Appendix C — Default role template

Discord role names are examples; the mapping uses role IDs.

| Discord role | Permission groups | Clearance and compartments |
|---|---|---|
| Aspirant | `patrol_basic` | internal |
| Officer | `patrol` | internal |
| Senior Officer | `patrol`, `fto` (with certification) | internal |
| Sergeant | `patrol`, `supervisor` | restricted |
| Lieutenant | `supervisor`, `command_view` | restricted |
| Captain / Chief | `command`, `personnel_admin` | confidential |
| Detective | `patrol`, `investigator` | restricted + unit compartment |
| Crime Scene Technician | `csi` | restricted |
| Lab Analyst | `lab` | restricted |
| Property Technician | `property` | restricted |
| Dispatcher | `dispatch` | internal |
| RUE Analyst | `intel_analyst` | confidential + `intelligence` |
| RUE Handler | `intel_handler` | confidential + `intelligence`, `sources` |
| RUE Commander | `intel_command` | secret + `intelligence`, `sources` |
| Internal Affairs | `ia` | confidential + `internal_affairs` |
| Judge | `court_judge` | confidential |
| Prosecutor | `court_prosecutor` | confidential |
| Court Clerk | `court_clerk` | internal |
| Defense Attorney | `defense` | open (discovery only) |
| FredPD Admin | `admin` | per configuration (admin does not imply record clearance) |

## Appendix D — Numbering formats

| Record | Format | Example |
|---|---|---|
| Person (master) | `P-{######}` | P-000431 |
| Report | `{AGENCY}-{YY}-{######}` | LSPD-26-000123 |
| Case | `{AGENCY}-C{YY}-{#####}` | LSPD-C26-00045 |
| Call | `{YYMMDD}-{####}` | 260917-0042 |
| Scene | `S{YY}-{#####}` | S26-00017 |
| Evidence | `E{YY}-{######}` (Code 128 barcode) | E26-001234 |
| Warrant | `W{YY}-{#####}` | W26-00088 |
| Citation | `{AGENCY}-T{YY}-{######}` | LSPD-T26-000311 |
| Booking | `B{YY}-{#####}` | B26-00102 |
| Lab request | `L{YY}-{#####}` | L26-00031 |

## Appendix E — Status tables

| Record | Statuses |
|---|---|
| Report | Draft → Submitted → Returned → Approved (locked); Voided (supervisor, with reason) |
| Case | Open → Active → Suspended → Closed (cleared by arrest, exceptionally cleared, unfounded, referred) |
| Warrant | Requested → Approved or Denied → Active → Served, Recalled or Expired |
| Evidence item | Collected → Temporary locker → In custody → Checked out → Returned → Disposed (released, destroyed, retained) |
| Lab request | Submitted → Accepted → In progress → Technical review → Released; Rejected (insufficient sample) |
| Call | Pending → Dispatched → En route → On scene → Cleared (disposition); Cancelled |
| Unit | Off duty, Available, En route, On scene, Busy, Transporting, At station, Out of service, Emergency |
| Call priority | P1 life-threatening or in progress; P2 urgent; P3 routine; P4 report only or scheduled |
| Citation | Issued → Paid, Contested (court) or Overdue |
| Impound | Impounded → On hold → Releasable → Released |

## Appendix F — Command line

Commands are localized through aliases (Swedish aliases in parentheses).

| Command | Action |
|---|---|
| `P <plate>` (`REG`) | Plate query |
| `N <last>, <first> [dob]` (`N`) | Name query |
| `S <serial>` (`VAP`) | Firearm query |
| `PH <number>` (`TEL`) | Phone query |
| `A <address>` (`ADR`) | Address query |
| `C <call>` (`H`) | Open call |
| `R <report>` (`AN`) | Open report |
| `E <evidence>` (`B`) | Open evidence item |
| `ST <code>` (`ST`) | Set unit status (AV, ER, OS, BU, TR, ST, OOS) |
| `ATT <call>` (`TILL`) | Attach own unit to call |
| `CLR <disposition>` (`KLAR`) | Clear current call |
| `MSG <unit> <text>` (`MED`) | Send message |
| `NEW R`, `NEW BOLO`, `NEW CASE` (`NY`) | Create record |

## Appendix G — References

- noobsystems/evidences: https://github.com/noobsystems/evidences
- ps-mdt v3: https://github.com/Project-Sloth/ps-mdt
- ox_mdt: https://github.com/overextended/ox_mdt
- overextended/fivem-ts: https://github.com/overextended/fivem-ts
- ox_inventory (Community Ox): https://github.com/CommunityOx/ox_inventory
- pma-voice: https://github.com/AvarianKnight/pma-voice
- Badger_Discord_API: https://github.com/JaredScar/Badger_Discord_API
- FiveM JavaScript runtime notes: https://docs.fivem.net/docs/scripting-manual/runtimes/javascript/
- Discord developer reference (CDN URL signing): https://docs.discord.com/developers/reference
- Claude Code memory (CLAUDE.md): https://code.claude.com/docs/en/memory
- Claude Code extensions overview: https://code.claude.com/docs/en/features-overview.md
