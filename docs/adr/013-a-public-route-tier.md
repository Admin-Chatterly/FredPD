# ADR-013: A public route tier, for the actions spec 8.10 gives to every player

- **Status:** Accepted
- **Date:** 2026-09-18
- **Spec:** 8.10, 8.3.4, 3.5, 4.1; invariant 3; narrows nothing, adds a second
  tier beside the one ADR-011 relies on

## Context

Invariant 3 says every client call goes through `route()`, and `route()` has
meant exactly one thing since M1: `Route.define`, whose first two checks are

```lua
local session = FredPD.Core.session.get(src)
if not session then return { ok = false, err = FredPD.ErrorCode.NO_SESSION } end
```

and then the permission. That is correct for every route written before M3,
because every one of them is an officer acting on a record.

`FredPD.Core.session.open` opens a session only for a player with an
`fpd_officers` row. A criminal has none, so a criminal has no session, so a
criminal cannot reach any route. Section 8 then asks for two things that only a
criminal does:

- **8.3.4** wants the person who left a print to be the owner of it. The owner is
  the hidden identifier of whoever touched the surface, and most of the people
  touching surfaces worth dusting are not police.
- **8.10** is explicit, and names the reference script's bug: destruction is
  "available to every player through ox_target, subject only to item and context
  rules. **Police-only restrictions must never block criminal gameplay.**"

Built on `Route.define`, both are unreachable. `forensics.observe` would answer
`no_session` to every non-officer, so no criminal would ever leave a trace, and
`forensics.destroy` would answer `no_session` to the same people, so no criminal
could ever clean one up. The entire adversarial half of section 8 — the half the
other half exists to investigate — would be dead on a real server while every
test in CI passed, because no test here opens a session for a player who has no
officer row.

The tempting shortcut is to open a session for everybody. It is the wrong
direction: a session carries `agencyId`, `officerId`, a permission set and a
staleness clock, and handing a synthetic one to a civilian would mean every
record path in the suite now has to ask whether the session in front of it is
real. That is a question no code currently asks, because until now the answer
could not be no.

## Decision

**Add a second tier to the same gateway: `Route.public`, in the same
`server/core/route.lua`, registering into the same `registered` table.**

A public route is still `route()`. It is still one `lib.callback.register` under
the same `fredpd:` naming, still answers the identical envelope
(`{ ok = true, data = … }` / `{ ok = false, err = code }`), still rate limited,
still schema validated, still runs its handler under `pcall`. Invariant 3 is not
being loosened — there is still exactly one place a client call can enter the
server, and it is still this file.

What it drops is the session and everything built on one:

```
Route.define   session → staleness → permission → context → rate limit → schema
               → handler → audit → response
Route.public                                      rate limit → schema
               → handler → response
```

Four details are deliberate:

- **`limit` is required and never defaulted.** A permissioned route is bounded
  twice, by who holds the permission and then by the limit, so falling back to
  the server default costs it little. A public route is bounded once. A public
  route without a limit is an unbounded call path open to every connected
  player, so one that forgets its limit does not start.
- **`schema` is required too, and for the identical reason.** On `Route.define`
  it is optional, because a route with no schema is still a route only a grant
  holder can call. Here the schema is the only thing that caps the size of what
  arrives and drops the keys the route never declared (invariant 1), and the
  caller is anybody who can connect. The argument that makes `limit` mandatory
  is the same argument word for word, so it produces the same assertion. A
  public route that genuinely takes no arguments declares an empty schema, which
  says so deliberately rather than by omission.
- **`perm`, `context`, `audit`, `auditDetail`, `writes`, `sensitive` and
  `subjectType` are rejected at load, loudly, by name.** Each needs a session to
  mean anything, so each would be a check that silently never runs. A public
  route quietly carrying a `perm` is the worst artefact this tier could produce:
  a route whose author believed it was protected.
- **The handler receives the numeric `src`, not a session table.** This is the
  whole safety argument, below.

`Route.names()` lists both tiers and `registered` is shared, so "route defined
twice" still catches a public route colliding with a permissioned one.

Two routes use it, and they are the two section 8 cannot express any other way:

| Route | Why it is public |
| --- | --- |
| `forensics.observe` | 8.3.4: the owner of a print is whoever left it, and that is usually not an officer |
| `forensics.destroy` | 8.10: wiping, cleaning, washing and picking up, for every player |

**A third public route is a decision, not a convenience.** Anything added here
is reachable by every connected player with no permission in front of it, so the
question to answer before adding one is not "does this need a session?" but "is
this an action spec grants to everyone?" Two do. If a third does, it gets an ADR
that says which clause grants it.

## Consequences

- **A public handler cannot read or write a record, and CI is what makes that
  so.** It holds a number, and every record path in this codebase needs a
  session: the repo layer takes the agency from `session.agencyId`,
  `FredPD.Core.access` takes the reader from `session`, and the audit row takes
  its actor from `session.discordId`. A handler that wanted a record would have
  to invent all three.

  The first draft of this ADR claimed the property held "because of the
  signature rather than because of a rule someone has to remember", and that was
  wrong in a way worth recording, because it was the load-bearing sentence. The
  signature hands the handler a number, but the number is a real server id, and
  `FredPD.Core.session.get(src)` is a global away: for a caller who happens to
  be an officer it returns the entire session, agency and permission set
  included. Nothing structural stopped it. What stops it now is check 6 in
  `tools/wiring-check.ts`, which reads every `route.public` handler body and
  fails the build on `FredPD.Core.session`, `FredPD.Core.perms`,
  `FredPD.Core.access`, `FredPD.Modules.access` or a repo. It is a rule someone
  has to remember only in the sense that CI remembers it for them.

  Public handlers therefore act on the world — the trace grid, the GSR table,
  the inventory bridge — and the world is not access-controlled, because
  everybody is standing in it.
- **The tier writes no audit row, and that is not an omission.** An audit row is
  attributed to a `discordId` (invariant 11, spec 4.4) and a public caller has
  none to attribute it to. Writing rows with a null actor would fill the log
  every officer reads with entries naming nobody, from every shot fired in the
  city.

  What this does *not* mean is that everything a public route does turns up in
  the log eventually. The two routes differ, and the first draft of this ADR
  flattened them into one false sentence — "what a public action becomes is
  audited where it enters a record, which is `evidence.collect`":

  - `forensics.observe` is audited that way. A trace it leaves becomes a record
    when an officer collects it, and `evidence.collect` writes the row.
  - `forensics.destroy` is not, and cannot be. Destruction produces no record at
    all: it removes a trace from the in-memory grid and adds one to the grid's
    `destroyed` total, a per-server counter with no player and no trace in it.
    There is nothing downstream to carry the act into the log.

    Nor is there anything upstream reading that counter today, and the first
    version of this bullet implied otherwise. It called `destroyed` "a per-server
    counter for the health screen (12.3)", which reads as a compensating control
    and is not one: `Grid.stats()` has no caller anywhere in the product — the
    only references outside its own definition are in `spec/forensics_spec.lua`
    — there is no `admin.health` route (the permission key `admin.health.view`
    sits in the catalogue with nothing claiming it), no NUI screen and no console
    command. Spec 12.3 is route timings and a load-test harness; system health is
    `[S]` in 7.30 and lands in **M7**. So the honest statement of this
    consequence is the flat one: **a trace destroyed by a sessionless caller
    currently leaves no observable signal on the server at all.** A criminal who
    wipes a door handle clean of a murderer's prints is invisible to everyone
    investigating it. That is the price of this tier as shipped, and it is
    accepted here rather than dressed up as a counter somebody can read.
    `destroyed` is kept for the M7 health screen — the milestone that ends this,
    by exposing `Grid.stats()` behind the `admin.health.view` that already exists
    — and until that screen lands it is a number incremented into a table nothing
    reads.

  The one row destruction can produce is written on the route's own side and not
  by the tier, because only the route can tell its two callers apart: an officer
  destroying evidence *does* have a session and therefore a `discordId` to name,
  and is audited; a criminal has none, so there is nothing to attribute a row to,
  which is the case this tier exists for. Two things bound that, and both matter.
  It takes an identity to **attribute**, never to **authorise** — no caller is
  refused on the strength of it, or the route would have grown the permission
  this ADR exists to keep off it. And it lives in a named helper beside the
  route rather than inline in the handler, which is exactly where check 6 draws
  its line: the check forbids the reflex of reaching for a session in a public
  handler, and leaves a deliberately-written attribution helper to be read as
  the decision it is. That is the check's floor, not a loophole in it — see the
  note on its scope in `tools/wiring-check.ts`.
- **The rate limit moves to first.** In `Route.define` it is fifth, behind four
  cheaper refusals. Here there is nothing ahead of it, so it is the only thing
  between a looping client and the handler, and it runs before the validator so
  a flood costs one bucket lookup rather than a full schema pass.
- **`tools/wiring-check.ts` had to learn the second tier**, and while it was
  being taught, it gained the check that would have caught this in the first
  place: a `lib.callback.await('fredpd:…')` anywhere under `resources/` naming a
  route no `route.define` or `route.public` declares. That is precisely how
  `forensics.destroy` shipped in ef88b44 — the client called it, nothing defined
  it, and every test passed.
- **It now also holds the two claims this tier is argued from.** Check 6 is the
  handler-body scan above, which is what turns "a public handler cannot reach a
  record" from a hope into a build failure. Check 7 is its mirror: a
  `PUBLIC_ROUTES` set naming the routes that must be public — the two in the
  table above — failing when one of them is declared with `route.define`. The
  assertion in `Route.public` already refuses a public route carrying a `perm`,
  so the regression it cannot see is the conversion in the other direction:
  `route.public` becomes `route.define`, a plausible `perm` goes on beside it,
  and 8.10's named bug is back with nothing in CI noticing. Adding a name to
  `PUBLIC_ROUTES` is the same decision as adding a public route, and costs the
  same ADR.
- **A public route answers `no_session` to nobody, and the satellite treats that
  code as a bug report.** `fredpd_forensics/client/destroy.lua` suppresses its
  prompt on `forbidden` and `no_session`, with a comment saying that receiving
  either means the route has been given a permission it must not have. That is
  now enforceable: the assertion above means such a route does not load at all.

## Alternatives considered

**Open a session for every player.** Rejected, and this is the one that would
have been quickest. A session is the officer identity: agency, officer id,
permission set, staleness clock. Making one for a civilian means every record
path in the suite gains a case it has never had to handle, and the failure mode
of missing one is a civilian session reaching a record — the opposite of what
this ADR is for.

**Give the criminal actions a permission and grant it to everyone in the seed.**
Rejected. It is 8.10's bug written down in SQL: a grant that must never be
removed is not a permission, and the first server administrator to tidy their
group table would silently switch off criminal gameplay with no error anywhere.

**A bare `RegisterNetEvent` for the two actions.** Rejected outright — it is
invariant 3's banned pattern and §11.3's first one, and it would give up the
envelope, the limiter and the validator to avoid writing forty lines beside the
route layer they already live in.

**Put the public routes in `fredpd_forensics`.** Not available: ADR-011 records
why a satellite cannot register a route at all, and the reasoning does not change
because the route happens to need no permission.
