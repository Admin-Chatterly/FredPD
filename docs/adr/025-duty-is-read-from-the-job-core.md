# ADR-025: Duty is read from the job core

- **Status:** Accepted
- **Date:** 2026-09-24
- **Spec:** 3.11, 4.3, 7.1
- **Amends:** ADR-008 (duty is read from `p_policejob`)

## Context

Every on-duty route (the motor pool, booking, forensics, cameras, the unit
board) asks `PoliceJob.isOnDuty`. It called an `isOnDuty` export on
`p_policejob`, and fell back to an ESX player variable `onDuty` that only
FredPD's own sign-on writes.

`p_policejob` exports no `isOnDuty`. pScripts keeps duty in its job core,
`piotreq_jobcore`, whose server export `isPlayerOnDuty(identifier)` takes the
character identifier. On a pScripts server the fallback therefore always read
"off", and nobody could do anything that requires duty. The name was a guess
that had never been checked against the resource.

## Decision

Duty is read from a list of sources, in order. The first one that answers
decides:

1. The job core named in `config/server.lua`'s `duty` table (`piotreq_jobcore`
   / `isPlayerOnDuty` by default), called with the character identifier. A
   boolean or a number counts as an answer.
2. `p_policejob`'s `isOnDuty`, for a version or fork that has one.
3. ESX's `job.onDuty`, which ESX Legacy 1.10 and newer keep on the job.
4. The flag FredPD sets where sign-on is configured to.

A source that is not started, lacks the export, or errors answers "cannot say"
and is skipped. If no source answers, the officer is off duty: a context
condition that fails open would let breaking the answering resource satisfy it.

`fredpd_duty <server id>`, run in the server console, prints what each source
says. That turns "I cannot go on duty" into a one-line diagnosis.

Ownership is unchanged. Going on duty happens where the police job does it,
never in the MDT (ADR-008). Duty remains a context condition and never a grant
(invariant 2).

## Consequences

- On a pScripts server, clocking in at the job's duty point is what FredPD
  sees.
- A server with another duty resource sets `duty.resource` and `duty.export`
  and changes no code.
- The bridge names `piotreq_jobcore` in the one file that already names the
  police job (3.8).
