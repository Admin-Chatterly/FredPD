# ADR-023: A subject route tier, for a caller's own records

- **Status:** Accepted
- **Date:** 2026-09-24
- **Spec:** 7.29, 3.5, 3.5.1; invariants 1, 3 and 4
- **Amends:** ADR-013 (a public handler never reaches a record)

## Context

Spec 7.29 asks for a civilian mode: a member of the public sees their own
citations and court decisions, and hands in a stolen-property report or a
complaint. They have no `fpd_officers` row and therefore no session, so
`route.define` answers `no_session`. `route.public` cannot serve them either.
ADR-013, spec 3.5.1 and `route.lua` all state that a public handler never
reaches a record, and `tools/wiring-check.ts` fails the build on a public
handler that names a repo. That check caught the first draft of this feature,
which is what it is for.

What civilian mode needs lies between the two tiers. The caller has an identity
of a kind, but not an officer's: the character the framework says they are
playing. The only records they may reach are the ones that name them.

## Decision

**A third tier, `route.subject`,** in the same `server/core/route.lua` and the
same registration table. It keeps the same envelope, limiter and validator
(invariant 3).

```
route.subject   rate limit → schema → subject → handler → audit → response
```

- **The wrapper resolves the subject, not the handler.**
  `FredPD.Core.subject.resolve(src, input.placementId)` requires the player to
  be standing at a public placement (`public_counter`, spec 3.10, checked on
  the server). It returns who the framework says the player's character is,
  and that character's person record. Nothing about identity is taken from
  input (invariant 1).
- **The handler receives the subject, never a session and never the player's
  server id.** The subject carries no `src`. Its name is the character's own,
  or empty, and never the identifier (11.4).
  It It reads only what
  is keyed on the subject: citations, åtal and reports that name this person.
  Other modules supply these through `*ForSubject` functions they own. Those
  functions show a record only when it is not restricted: open or internal,
  in no compartment, and not sealed. This is the same line a paper copy draws
  (ADR-020). The desk is not a way round a seal.
- **Held at load, too.** `Route.subject` refuses to start a route that is
  missing from its own allowlist, or whose schema does not declare
  `placementId`.
- **Held by CI, like the public tier.** `wiring-check.ts`:
  - fails a `route.subject` declared anywhere but a `routes.lua`;
  - fails a `route.subject` that is not in its `SUBJECT_ROUTES` allowlist,
    where each entry carries a reason;
  - fails a subject handler that names the session, a permission set, an
    access check or the resolver itself;
  - fails a subject handler that never reads `subject.`;
  - fails a listed route declared with any other tier.
- **Rate limit and schema are required,** as on the public tier. The schema
  must carry `placementId`.
- **Audit.** A subject route may declare `audit`. Its row names the agency and
  what happened, never an officer (none acted) and never what the subject
  wrote.
- **Public placements reach every player.** A front desk's geometry is sent to
  anyone who asks, through `placements.public`, which is a public route that
  touches no record. The officers' own placements still come with their
  session.

## Consequences

- A member of the public can see what the police hold on them that a paper
  copy would also have shown them. They can hand in a report without an
  officer, and the right inbox is told: a complaint about the police reaches
  internal affairs (`ia.case.view`), not the shift.
- There are now two sessionless tiers. The public tier still never reaches a
  record, and the subject tier reaches only the caller's own. A new subject
  route is a decision with an ADR, as a new public route is under ADR-013.
- The subject is only as good as the framework's character lookup. That is
  the same trust `field.person.resolve` already places in it for an arrestee.
