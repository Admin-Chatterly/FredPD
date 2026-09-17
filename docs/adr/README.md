# Architecture decision records

One file per decision, numbered, never rewritten once accepted. A decision that
turns out wrong gets a new ADR that supersedes the old one — the record of
having believed it is part of the value.

Format: context, decision, consequences, alternatives considered.

When a decision changes `docs/FredPD.md`, the ADR and the spec edit go in the
**same pull request** (spec, "How to use this document").

| ADR | Decision | Status |
| --- | --- | --- |
| [001](001-lua-server.md) | Lua 5.4 with ox_lib for server scripts | Accepted |
| [002](002-svelte-nui.md) | Svelte 5 + TypeScript + Vite for the NUI | Accepted |
| [003](003-gateway-service.md) | A separate Node.js gateway service | Accepted |
| [004](004-discord-permissions.md) | Discord roles as the only permission source | Accepted |
| [005](005-esx-framework.md) | ESX as the target framework, behind a bridge | Accepted |
