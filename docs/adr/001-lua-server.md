# ADR-001: Lua 5.4 with ox_lib for server scripts

- **Status:** Accepted
- **Date:** 2026-09-17
- **Spec:** 3.3, 3.4

## Context

FredPD's server logic runs inside FXServer. FiveM supports Lua, JavaScript and
C#. The suite is large — records, dispatch, evidence, lab, court, personnel —
and will be maintained for years, so the choice has to survive far past the
first milestone.

The surrounding ecosystem the server already runs (ox_lib, ox_inventory,
ox_target, oxmysql, pma-voice) is Lua, and every integration example, bridge
pattern and community reference is written against it.

## Decision

Server and client scripts are **Lua 5.4** (`lua54 'yes'` in every manifest),
using **ox_lib** for callbacks, caching and utilities.

The NUI is the exception and is TypeScript (ADR-002), as is the gateway
(ADR-003). Lua is for what runs inside FXServer.

## Consequences

- Native and ecosystem integration is direct, with no interop layer.
- Lua 5.4 gives integer division, bitwise operators and `<const>`, which the
  older 5.3 runtime did not.
- Lua's tooling is weaker than TypeScript's. We compensate deliberately:
  luacheck with an explicit `read_globals` allowlist so an accidental global is
  an error, lua-language-server diagnostics, and validator tables **generated**
  from the TypeScript schema rather than hand-written (spec 3.5). That
  generation step is what keeps a dynamically typed server honest about the
  shapes it accepts.
- `service.lua` files are required to contain no natives, so the logic worth
  testing is testable with busted outside the game.
- Structured concurrency is manual. Anything long-running yields with `Wait`.

## Alternatives considered

**JavaScript on FXServer's Node runtime.** Better typing and a larger standard
library, but every ecosystem resource we bridge to is Lua, so every integration
would cross a boundary. The typing benefit is recovered by generating validators
instead.

**C#.** Strongest typing of the three, weakest ecosystem fit and slowest
iteration; hot-reloading a C# resource during development is materially worse.
