---
name: new-bridge
description: Add or change a bridge to another FiveM resource (phone, jail, billing, garage, housing, dispatch, ALPR, doorlock). Use whenever FredPD must talk to a resource it does not own.
---

# Adding a bridge

Read spec **3.8**. A bridge is the **only** place FredPD names another resource.
That rule is what lets a server swap its phone or its framework without a change
anywhere else — and it is why ESX lives behind
`server/bridges/framework.lua` and nowhere else in the codebase.

## 1. Define the contract first

Write the interface FredPD needs, in FredPD's own vocabulary — not the other
resource's. `getCharacter(src)` returns what FredPD calls a character, whichever
framework supplies it. If the contract leaks the other resource's field names,
the bridge has failed at its one job.

## 2. Implement it

`server/bridges/<name>.lua`:

```lua
FredPD.Bridge = FredPD.Bridge or {}

local Phone = {}

function Phone.verify()
    if GetResourceState('lb-phone') ~= 'started' then
        error('[fredpd] phone bridge: lb-phone is not started.')
    end
end

FredPD.Bridge.phone = Phone
```

- **Check at startup, not on first use** (spec 3.8): `verify()` runs from
  `server/main.lua` and fails loudly, naming the missing resource.
- Where a server may run one of several implementations, select it from
  `config/server.lua` and keep each in its own file.
- Return `false` or `nil` for "this server has no such feature", distinctly from
  an error meaning "the call failed". The caller needs to tell those apart.

## 3. What a bridge must never do

- **Never grant a permission.** Discord roles are the only source (invariant 2).
  A job, a grade or a duty flag from another resource is a *context condition*
  on a grant that already exists — never the grant itself.
- **Never trust the other resource's data as identity.** An identifier arriving
  from anywhere but the server's own lookup is input, not truth.
- Never let another resource write a FredPD record directly. It goes through a
  service, with the same validation and audit as any other write.

## 4. Integration API

If other resources should call *into* FredPD, that is section **14**, not a
bridge. Exports are a public contract: validate their arguments as strictly as a
route does, and never return a restricted record to an unauthenticated caller.

## 5. Tests

The contract, with a faked target resource, in busted. Test the missing-resource
path too — a server without that resource must get a clear error, not a nil
index deep inside a module.

## Before you finish

`pnpm check`, then the `security-reviewer` subagent.
