# fredpd/ — the core resource

Lua 5.4 with ox_lib, oxmysql and ESX. Read spec sections 0, 3.4, 3.5 and 4
before working here.

## Structure

```
config/      shared.lua (client-safe) and server.lua (never in files {})
shared/      namespace, locale loader, generated/ schema
server/core/ route, session, perms, access, validate, audit, ratelimit, …
server/bridges/  the only place another resource is named
server/modules/<name>/  service.lua, repo.lua, routes.lua, events.lua
client/      NUI host, access points, status keys, camera
```

## Rules specific to this resource

- **Every client call is a route.** Define it with `route { … }`; never add a
  bare `RegisterNetEvent` that changes state (invariant 3). The wrapper order is
  fixed: session → staleness → permission → context → rate limit → schema →
  handler → access checks → audit → response.
- **The session is the truth.** `session.officerId` and `session.agencyId` come
  from the server. An officer id arriving in `input` is an attack, not a field.
- **`service.lua` holds the logic and no natives**, so busted can test it.
  `repo.lua` holds the SQL. A module never reaches into another module's repo.
- **Parameterized SQL only** (invariant 8). No string concatenation, ever.
- **Never broadcast a record.** Push to subscribed, authorized sessions only,
  filtered through the same access checks as a read (invariants 4 and 5).
- **Permissions come from Discord** (invariant 2). ESX job and duty state are
  context conditions layered on a grant, never a grant themselves.
- **No user-facing string in Lua.** Use `FredPD.t('key')`, and add the key to
  both `locales/en.json` and `locales/sv.json`.
- `shared/generated/` is written by `pnpm schema:gen`. Never edit it by hand.

## Adding a migration

`database/migrations/` is append-only (invariant 8). Add a new numbered file;
never edit one that has shipped, not even a comment.
