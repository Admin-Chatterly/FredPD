# ADR-018: Licence points, and a tariff the agency edits

- **Status:** Accepted
- **Date:** 2026-09-24
- **Spec:** 7.11, 7.3, 4.5

## Context

The ordningsbot tariff (0019) is versioned and immutable, but nothing ever
filled it. No seed wrote a line, no route wrote one, and `Repo.setTariff`
had no caller. On a real server an officer choosing "Cite" was shown an empty
list, so no citation could be issued in the game at all. Spec 7.11 also
recorded points on a licence as not built: the suite has no licence concept.

Sweden has no points system. A licence is revoked (*återkallat*) by
Transportstyrelsen after certain offences, and the rules behind that decision
are ones a game server cannot follow. Players nevertheless expect repeated
traffic offences to catch up with them, and an officer at a stop needs to know
whether the driver may drive.

## Decision

- **Each tariff line carries its own points** (`licence_points`, 0 to 20,
  migration 0036). They are written on the version, like the amount, so a
  citation keeps the points it was issued under.
- **A licence's standing is computed, not stored.**
  - The points are the sum over citations that name the person, are still
    `issued` or `paid`, and are younger than `ordningsbot.licence.windowDays`.
  - Up to three quarters of `threshold` the licence is `valid`. From three
    quarters it is `warning`. At `threshold` it is `revoked`.
  - Voiding or contesting a citation takes its points away immediately.
  - **Only citations the reader may see count.** The counting rows go
    through the same `filterSearch` as a citation list. A total that
    disagreed with the citations a reader can list would reveal that
    hidden or court-sealed ones exist. So two readers can see different
    totals for the same person, and that is the correct outcome.
  - Nothing expires on a timer. This is the same "computed from dates" shape
    as the payment status and the impound fee.
- **Points land only on a named person.** A fine sent to a vehicle's keeper
  does not say who was driving.
- **Where it is shown:**
  - on the person record;
  - in the field ID check;
  - in the answer to `ordningsbot.issue`, so the officer who wrote the fine
    sees what it did.

  In every case it is shown only to a session holding `ordningsbot.view`, and
  only for a person that session has already read through the access check.
- **The Swedish term.** The Swedish text uses *prickar* for the points and
  *återkallat* for the revoked state. *Prickar* is the nearest real Swedish
  word (the Norwegian and Danish systems use it) and is flagged here as a
  game adaptation, not Swedish law.
- **Nothing is written to another resource.** A revoked licence is a fact on
  the record, not a removed `drive` licence in esx_license. If that is
  wanted, it is a bridge with its own ADR.
- **A label is data, never markup.** ox_lib renders menu text as markdown,
  so the server refuses a label containing link, image or HTML syntax or a
  control character, and the client escapes it anyway.
- **The agency's command edits the tariff** through
  `ordningsbot.tariff.set` and `.retire`, with permission
  `ordningsbot.tariff.edit`, granted to `command` in the seed.
  - A save is a new version. The retire and the insert happen in one
    transaction, as 0019 requires.
  - A line the agency adds is named in its own words (`label`) and carries
    the sentinel key `ordningsbot.tariff.custom`. The shipped lines keep
    their locale keys, so they read in both languages.
  - Both routes are `sensitive`, like the offence catalogue's, and audited.
    The label is included in the audit.
- **An empty agency gets the shipped catalogue at start.** It comes from
  `ordningsbot.defaultTariff` in `config/server.lua`, and is written only
  for an agency that has never had a tariff line. An agency that retired
  every line did so on purpose, and its catalogue stays empty.
- **`ordningsbot.issue` now reads the person and the vehicle it names**
  through the access check, and answers not found otherwise. It did not
  before. Now that its answer carries a licence standing, it would otherwise
  have been a way to learn about a hidden person.

## Consequences

- Citations work on a fresh install without anyone writing SQL.
- A server that wants no points sets `licence.enabled = false`. The points
  column is then ignored, and the editor hides it.
- The permission catalogue in `admin/routes.lua` was missing every
  ordningsbot, impound, booking and personnel key the routes check. They were
  added, and `tools/wiring-check.ts` now fails when the seed or a route names
  a key the catalogue lacks.
