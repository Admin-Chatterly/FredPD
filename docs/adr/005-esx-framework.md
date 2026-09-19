# ADR-005: ESX as the target framework, behind a bridge

- **Status:** Accepted
- **Date:** 2026-09-17
- **Spec:** 3.3, 3.8, 4.1
- **Supersedes:** the QBox (`qbx_core`) assumption in spec v0.1

## Context

Spec v0.1 was written against QBox (`qbx_core`) throughout: the target platform,
the framework bridge's default implementation, the database note, and the
identity model's use of `citizenid`.

The server this is actually being built for runs **ESX** (`es_extended`).

The rest of the stack is unaffected. ox_lib, oxmysql, ox_target, ox_inventory
and pma-voice all support ESX, and every one of them is already a bridge or a
direct dependency rather than something coupled to a framework.

## Decision

The target framework is **ESX (`es_extended`)**.

The framework is reached only through `server/bridges/framework.lua` (spec 3.8).
That file names `es_extended`; nothing else in the codebase does.

Identity (spec 4.1) binds to the **ESX character identifier** — `char1:license:…`
on a multi-character server, the bare licence otherwise — in place of QBox's
`citizenid`. The Discord identifier, which is what access actually depends on,
is read with `GetPlayerIdentifierByType(src, 'discord')` and is framework-
independent, so ADR-004 is untouched.

`docs/FredPD.md` was updated in the same change, as the spec's own amendment
rule requires.

## Consequences

- The change was small and stayed small — three lines of code and nine lines of
  spec — because section 3.8 had already confined the framework to one file.
  This is the bridge design paying for itself before M1.
- ESX has **no duty concept of its own**; servers model it as a job or as player
  metadata. `Framework.setDuty` therefore returns whether it was handled, so a
  caller can tell "refused" from "this server has no such thing". The duty
  integration in spec 7.1 stays configurable, as written.
- ESX job grades grant nothing, exactly as QBox grades granted nothing
  (invariant 2). The wording in spec 0 changed; the rule did not.
- FredPD's tables are prefixed `fpd_` and share the ESX database, as they would
  have shared the QBox one.
- If this server ever migrates framework, the work is a second implementation of
  the same bridge contract — not a change spread across modules.

## Alternatives considered

**Support ESX and QBox simultaneously from the start.** The bridge contract
makes it possible, but paying for a second implementation before the first
framework is proven is speculative work. The contract keeps the option open at
roughly the cost of writing the adapter when someone actually needs it.

**Depend on ESX directly, without the bridge.** Slightly less code today. It
would put a resource name into every module that touches identity or duty, and
it is precisely what invariant-adjacent rule 3.8 exists to prevent.
