# ADR-008: FredPD coexists with p_policejob rather than replacing it

- **Status:** Accepted (amended by ADR-025: duty is read from the job core)
- **Date:** 2026-09-17
- **Spec:** 3.11, 3.8, 7.15, 7.31

## Context

The server runs `p_policejob`, which already provides the in-world police job:
duty toggle, armory, cloakroom, garage and impound. FredPD's scope overlaps it
at the edges — spec 7.15 describes impound, 7.1 describes duty — and FredPD
brings its own MDT, which `p_policejob` also has in some form.

Two systems each believing they own duty state is the kind of overlap that
produces an officer who is on duty in one and off in the other.

## Decision

`p_policejob` keeps the in-world job. FredPD owns records, dispatch, evidence,
lab, court, intelligence and the MDT. One owner per concern (spec 3.11):

| Concern | Owner |
|---|---|
| Duty toggle, armory, cloakroom | `p_policejob` |
| Impound and tow | `p_policejob` |
| Agency motor pool | FredPD (7.31) |
| MDT, records, CAD, evidence, court | FredPD |
| Permissions for any of it | FredPD, from Discord roles |

A `policejob` bridge is the only place that names the resource. Duty and rank
are read through it as **context conditions**, never as grants: a `p_policejob`
rank grants nothing, exactly as an ESX job grade does not (invariant 2).

The motor pool is the one deliberate exception, taken because FredPD needs to
gate vehicles on FredPD permissions and certifications and to log every draw
against an officer — neither of which `p_policejob` knows about. Impound is
*not* taken, because it already works and has no such requirement.

## Consequences

- Nothing breaks on the day FredPD is installed. There is no cutover, and no
  period where officers cannot go on duty because the replacement is half done.
- Spec 7.15 (impound) is descriptive rather than a build target for now: FredPD
  reads impound state through the bridge and links to it from a vehicle record,
  but does not own it.
- **Two garages exist** — `p_policejob`'s and FredPD's motor pool. That is a
  real cost and the most likely source of confusion, so the motor pool is a
  placement (ADR-006) and can simply not be placed on a server that would rather
  keep using the existing one. Feature, not fork.
- Duty is read, not written, in the normal case. FredPD sets duty only where
  spec 7.1 says sign-on should, and that stays configurable.
- If `p_policejob` is ever removed, the work is a second implementation of the
  same bridge contract, not a change spread across modules.

## Alternatives considered

**Replace `p_policejob` entirely.** One coherent system and one place to
configure, but it front-loads duty, armory and cloakroom work that the spec puts
nowhere near M1, and demands full parity before the switch can happen. Still the
likely end state after M6; this ADR does not close that door.

**Replace it immediately, in M1.** Same benefit, and it would delay the records
core that spec 17.1 treats as the priority — building a cloakroom before a
person record is the wrong order for a records suite.

**Let both own duty.** Rejected outright: two writers, no owner, and an officer
whose state depends on which resource answered last.
