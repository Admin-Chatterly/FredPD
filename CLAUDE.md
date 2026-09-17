# FredPD

Police records, dispatch, evidence and forensics suite for an ESX FiveM server.

`docs/FredPD.md` is the single source of truth. Read **section 0 (invariants)**
before every task, plus the section for whatever you are building. This file is
only a pointer; the spec has the detail.

## The rules that override everything

1. **Server-authoritative.** Clients send intent. The server decides. Authors,
   officers, timestamps, record numbers and analysis results are generated
   server-side, never accepted from input.
2. **Discord roles are the only permission source.** ESX job grades grant
   nothing; jobs and duty are *context conditions* on top of a Discord grant.
3. **One gateway.** Every client call goes through `route()`. No raw
   `RegisterNetEvent` handler may change state.
4. **Access is checked on the server for every read**, search results and
   exports included. Hiding something in the UI is never the control.
5. **No record broadcasts.** Never `TriggerClientEvent(..., -1, record)`.
6. **No hardcoded user-facing text.** `en` and `sv` both complete, or CI fails.
7. **No secrets on clients.** `set` convars, never `setr`; never in `files {}`.
8. **SQL is parameterized. Migrations are append-only** — never edit one that
   has shipped.
9. **Media only through the gateway**, with signed URLs and the NUI's CSP.
10. **Rich text is editor JSON.** Raw HTML is never rendered.
11. **The audit log is append-only.** Reads of restricted records are audited.
12. **The UI follows section 6**: realistic agency software. No gradients,
    glass, glow, neon or emoji icons.
13. **Performance budgets in section 12 are acceptance criteria.**

## Layout

| Path | What lives there |
| --- | --- |
| `resources/[fredpd]/fredpd/` | Core resource: routes, sessions, permissions, modules |
| `resources/[fredpd]/fredpd_forensics/` | Evidence generation and scene tools (M3) |
| `resources/[fredpd]/fredpd_surveillance/` | Interception, warrant-gated (M5) |
| `resources/[fredpd]/fredpd_assets/` | Streamed props and sounds |
| `web/` | Svelte 5 NUI, builds into `fredpd/web/dist` |
| `gateway/` | Node.js service: Discord sync, media, PDF, scheduler |
| `packages/schema/` | Route and entity schemas → TS types **and** generated Lua |
| `database/migrations/` | Append-only, numbered |
| `tools/` | i18n checker, codegen |
| `resources/[fredpd]/fredpd/spec/` | busted tests for the pure service logic |
| `vendor/pd-span/` | PD-Span source, for the intelligence integration (section 10) |

## Commands

```
pnpm install
pnpm dev:web          # NUI in a browser against fixtures, no game server
pnpm build            # schema → NUI → gateway
pnpm check            # lint, types, svelte-check, i18n
pnpm test             # unit tests (Vitest)
pnpm test:lua         # Lua unit tests (busted)
pnpm lint:lua         # luacheck over the resources
pnpm test:e2e         # Playwright against the mock bridge
pnpm schema:gen       # regenerate the Lua schema; commit the result
```

## Conventions

- A module calls another module through its `service.lua`, never its `repo.lua`.
- `service.lua` contains no natives, so it is unit-testable with busted.
- Bridges are the only place that names another resource. `es_extended`,
  `p_policejob`, `esx_society`, `esx_textui` and `esx_menu_dialog` each live in
  exactly one bridge file and nowhere else.
- Anything with a world position is a **placement** row, configured in game
  (spec 3.10) — never a coordinate in a config file.
- Every user-facing string is a locale key in `resources/[fredpd]/fredpd/locales/`.
- `shared/generated/` is generated. Change `packages/schema/src/` and regenerate.

## Definition of done

Spec acceptance criteria met · invariants respected · tests added and passing ·
`en` and `sv` complete · permissions added to Appendix B and the seed ·
ADR written if a decision changed.
