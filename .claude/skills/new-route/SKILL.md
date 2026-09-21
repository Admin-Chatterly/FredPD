---
name: new-route
description: Add a client-callable route to the FredPD core resource, with its schema, permission, audit entry and tests. Use whenever the NUI needs to call the server for something new.
---

# Adding a route

Every client call is a route (invariant 3). The wrapper is the security
boundary, so this checklist is not optional. Read spec **3.5** and **4.3**.

## 1. Define the input schema

`packages/schema/src/routes/<module>.ts` — the shape, its types, enums, lengths
and which fields are required. Then `pnpm schema:gen` and commit the generated
Lua. Never hand-write the Lua validator table.

## 2. Add the permission

- Add the key to **Appendix B** in `docs/FredPD.md`.
- Add it to the permission seed in `database/seeds/`.
- Name it `<module>.<entity>.<action>`, e.g. `court.warrant.request`.

## 3. Write the route

In `server/modules/<module>/routes.lua`:

```lua
route {
    name    = 'warrant.request',
    perm    = 'court.warrant.request',
    context = { onDuty = true },        -- omit when there is no condition
    schema  = 'WarrantRequest',
    limit   = { per = 10, window = 60 },
    audit   = 'warrant.requested',
    handler = function(session, input)
        return warrants.request(session, input)
    end,
}
```

- `session.officerId` and `session.agencyId` come from the session. An officer
  id in `input` is an attack, not a field.
- The handler delegates to `service.lua`. Put no logic in the route itself.
- Record-level access checks belong inside the service, on every read it does.

## 4. Implement the service

`server/modules/<module>/service.lua` holds the logic and **no natives**, so
busted can test it. `repo.lua` holds the parameterized SQL. A service never
touches another module's repo.

## 5. Locale keys

Any new failure a user can see needs `error.<code>` or a module key in **both**
`locales/en.json` and `locales/sv.json`. Check Appendix A for the Swedish term.

## 6. Tests

- busted: the service's logic, including the refusal paths.
- Route contract: every case in spec **11.5** — no session, stale session, wrong
  permission, failed context, rate limit, invalid schema, unknown field.

## 7. The NUI side

Add a fixture in `web/src/lib/nui/fixtures.ts` so the screen works in a browser,
and call it through `nui.call()` — never `fetch`.

## Before you finish

`pnpm check && pnpm test`, then the `security-reviewer` subagent.
