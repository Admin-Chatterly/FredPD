# ADR-006: World positions are configured in game, not in config files

- **Status:** Accepted
- **Date:** 2026-09-17
- **Spec:** 3.10, 1.4, 7.30, 7.31

## Context

FredPD is full of things that exist somewhere in the world: station terminals,
the property room counter, lab benches, the booking station, the dispatch
console, the courthouse desk, motor pool peds. Spec 1.4 ties real features to
these access points — evidence intake only works at the property terminal, lab
analysis only at the lab.

The FiveM convention is to put those coordinates in a Lua config table. That
means the person who knows where the desk should be (the server owner, standing
in the station looking at it) cannot move it, and the person who can move it
needs a file edit, a commit and a restart. Coordinates get copied out of a
third-party MLO thread and are wrong by a metre. Every map change is a code
change.

## Decision

Every world position is a **placement** row in `fpd_placements`, created and
edited in game by an administrator holding `admin.placement.edit` (spec 3.10).

A placement binds a location to a `kind` — which UI element or feature it opens
— with an interaction style (`prop`, `ped` or `zone`), an optional model, a
radius and a locale key for its prompt. `/fredpd placement` opens an editor:
aim at a prop to bind it, or place a ped with a live preview, then pick what it
opens.

Two rules make this safe rather than a permission hole:

1. **A placement decides *where*, never *who*.** It is an entrance, not a grant.
   Permission still comes from Discord roles and is checked on the server for
   every route the element calls (invariants 2 and 4). Deleting a placement
   removes a door, not an authorisation.
2. **Placements are verified server-side.** A route invoked "from" a placement
   carries its id, and the server checks the player is genuinely within `radius`
   of that placement before honouring the access-point context condition.

## Consequences

- The people who know where things belong can put them there, standing in front
  of them, without a developer or a restart.
- Access points stop being a deployment concern and become configuration, which
  is what spec 1.4 always implied they were.
- Moving a map or swapping an MLO is an afternoon with the editor rather than a
  code change.
- **Cost: a new trust boundary.** Without rule 2, "only at the property
  terminal" would mean nothing, because any client could claim to be standing
  at it. The proximity check is the control; the client's claim is input.
- Placements are pushed to clients as world geometry only — coordinates, models
  and label keys. No permission data goes with them. A client knowing a door
  exists is not a client that can open it.
- Prompts use `label_key`, not a literal string, so the editor cannot be used to
  route around invariant 6.
- One more table and one more editor to maintain. Worth it: the alternative is
  a config file that is wrong in a different way on every server.

## Alternatives considered

**Lua config tables**, the convention. Zero new code and no trust boundary, but
it puts a restart between the person with the knowledge and the change, and it
is why so many FiveM installs run with a terminal floating inside a wall.

**A config file edited through the MDT.** Keeps the file as the source of truth
but needs write access to disk from the server, and gives up transactional
writes, audit and per-agency scoping that a table gets for free.

**Convars.** Fine for a handful of scalars, hopeless for a list of positioned
objects with models and bindings.
