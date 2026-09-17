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

## Status

**M0 — repository and tooling.** The monorepo, toolchain, CI and the mock NUI
bridge are in place; the resources start clean. The platform core lands in M1
(see the roadmap in spec section 17).

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
| `pnpm test:e2e` | NUI tests in a browser (Playwright) |
| `pnpm schema:gen` | Regenerate the Lua schema — commit the result |
| `pnpm i18n:check` | `en` and `sv` complete and consistent |

### Running it on a server

Beyond M0 this needs an FXServer with ESX, ox_lib, oxmysql and ox_target, a
MariaDB database, and the gateway service. Build first — the NUI is served from
`resources/[fredpd]/fredpd/web/dist`, which `pnpm build` produces.

```
set fredpd:gateway_secret "<openssl rand -hex 32>"   # `set`, never `setr`
set fredpd:discord_guild  "<guild id>"
setr fredpd:locale sv
```

Gateway configuration lives in the environment; copy `.env.example` to `.env`.

## Working on it

`CLAUDE.md` at the root, and in `web/`, `gateway/` and the core resource, carry
the conventions for each area. `.claude/` holds the review subagents
(security, UI, i18n, performance), task skills, and hooks that block the things
the invariants forbid — editing a shipped migration, writing a secret into the
repo, hand-editing generated code.

Contributions follow the definition of done in spec 15: acceptance criteria met,
invariants respected, tests passing, `en` and `sv` complete, permissions
recorded, and an ADR when a decision changed.
