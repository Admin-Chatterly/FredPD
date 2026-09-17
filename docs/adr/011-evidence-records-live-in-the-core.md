# ADR-011: Evidence records live in the core resource; satellites hold only in-world mechanics

- **Status:** Accepted
- **Date:** 2026-09-17
- **Spec:** 8, 9, 3.1, 3.5; supersedes nothing, narrows ADR-008's ownership table

## Context

`fredpd_forensics` and `fredpd_surveillance` have been empty scaffolds since M0.
Starting M3 exposed why they could not simply be filled in.

Every client-to-server call in FredPD goes through `route()` (invariant 3),
which is defined in `server/core/route.lua` **inside the `fredpd` resource**.
FiveM gives each resource its own Lua state, and the core's `fxmanifest.lua`
declares no `exports` — so `FredPD.Core.route.define` is not reachable from
`fredpd_forensics` at all. A satellite resource cannot register a route, open a
session, check a permission or write an audit row.

Exporting the route layer would not fix it cleanly either: an export call
serialises its arguments across the resource boundary, and a route definition is
mostly a handler *function*.

So the question is not "how do satellites register routes" but "should they".

## Decision

**They should not.** Records live in the core; satellites hold in-world
mechanics only.

- `fredpd/server/modules/evidence/` owns the tables, the routes, custody, the
  lab queue and the forensic indexes. Migration `0002_evidence.sql` creates
  them.
- `fredpd_forensics` owns what needs the game and nothing else: raycasts,
  evidence markers, powder and luminol effects, timed collection actions,
  prop placement. It reaches the core through a narrow server-to-server
  `exports` surface carrying plain data — never a session, never a permission
  decision, never forensic truth.
- `fredpd_surveillance` will follow the same split in M5.

This is what ADR-008's ownership table already implied — "MDT, records, CAD,
evidence, court → FredPD [core]" — and what spec 3.1's own description of the
satellites says: "in-world evidence generation, scene tools, packaging,
destruction mechanics". It is recorded here because the M0 scaffolding read as
though each satellite were a self-contained vertical slice, and building one
that way would have meant either duplicating the route layer or weakening it.

## Consequences

- The permission, session, staleness, rate-limit, schema and audit wrapper
  applies to every evidence action, because every evidence action is a core
  route. That is invariant 3 holding rather than being re-implemented twice.
- A satellite cannot decide anything. It reports "a shot was fired here, by
  this player, with this weapon"; the core validates position, entity and
  weapon against its own state (8.3.2) and decides what, if anything, exists.
  The reference script's failure mode — a generic net event that calls any
  method with client arguments, §11.3's first banned pattern — is not available
  from this shape.
- `fredpd_forensics` stays a small resource. Most of M3's 60–80 hours lands in
  the core, which is where the tests already run.
- The export surface between them is the one thing to watch: it must carry data
  and not authority. A future export that returns a DNA profile, an owner or a
  quality score to the satellite would put hidden truth one `TriggerClientEvent`
  away from a client, defeating 8.1 and 8.11.
- Satellites remain separately startable and separately versioned, which is what
  the split was for: a server that does not want forensics does not start
  `fredpd_forensics`, and the core loses a feature rather than failing.

## Alternatives considered

**Export the route layer.** Rejected: handlers are functions, exports serialise,
and the result would be a second, weaker registration path beside `route()` —
exactly what invariant 3 exists to prevent.

**Merge the satellites into the core.** Simplest, and genuinely tempting. Kept
separate because `fredpd_surveillance` will depend on `pma-voice` and
`fredpd_forensics` on `ox_target`, and forcing every install to carry those
dependencies to run the MDT is worse than the boundary being slightly awkward.
