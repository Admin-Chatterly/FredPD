# ADR-014: Swedish procedure, not US workflows with Swedish labels

- **Status:** Accepted
- **Date:** 2026-09-18
- **Spec:** 7.7–7.13, 19
- **Supersedes:** the US procedural assumptions in spec v0.1

## Context

Section 19 listed this as an open decision due by M2:

> Procedure style: US-style workflows with Swedish text, or Swedish-style
> procedure (gripande, anhållande, häktning, prosecutor-led förundersökning)

Spec v0.1 was written against a US records system throughout. Sections 7.7–7.13
describe an incident report a supervisor approves, an arrest with a rights
advisement, a warrant a judge signs, a BOLO, and a penal code with a class and a
fine per offence. Appendix A was the concession to Sweden: a translation table,
applied at the surface.

The department being built for is Swedish. The question was whether that is a
matter of vocabulary or of shape.

## Decision

**Swedish procedure.** The workflows follow rättegångsbalken and brottsbalken,
and Appendix A stops being a translation table and becomes the vocabulary the
modules are written in.

This is a decision about structure, not about words. Four places where the two
readings produce genuinely different software:

### One record became two (7.7, 7.8)

A US report is approved by a supervisor and then becomes a case. In Swedish
procedure an **anmälan** is a report of an offence and a **förundersökning** is
the investigation, and they have different owners: a supervisor approves the
first, and the second is opened by a decision, led by a
**förundersökningsledare** who may be an **åklagare**, and ended by a decision.

Merging them would have made a supervisor's approval and a prosecutor's decision
to drop a case the same column.

### One arrest became a chain of three (7.9)

A US arrest is one record with one arresting officer. Swedish procedure deprives
somebody of liberty in three decisions taken by three different people:
**gripande** (RB 24:7, the officer), **anhållande** (RB 24:6, the åklagare) and
**häktning** (RB 24:13, the tingsrätt).

It also puts statutory clocks between them, and one of those is the reason this
decision could not be deferred: RB 24:12 gives the häktningsframställan until
*klockan tolv tredje dagen efter anhållningsbeslutet*. A wall-clock noon, not
seventy-two hours — 76 hours for a morning anhållande, 62 for an evening one. A
US-shaped module with Swedish labels would have counted 72 and been quietly wrong
on every detention.

### The judge left most of the warrants (7.12)

**Husrannsakan** (RB 28:1) and **kroppsvisitation** (RB 28:11) are decided by the
förundersökningsledare — police or prosecutor — not by a court. A model that put
every coercive measure through a judge would have stopped the commonest one in
the suite on a server with nobody playing one.

The **arrest warrant has no Swedish equivalent at all**. What FredPD needed it
for is an **efterlysning**, and the case behind most of them —
*anhållen i sin frånvaro* — is a decision that already lives in the
frihetsberövande chain.

### The penal code became a span (7.10)

A US offence carries a class, a fine and a jail time. A Swedish one carries a
**straffskala**: whether böter is available, a floor, and a ceiling that is
sometimes absent entirely. Filling in the US shape would have meant inventing
five numbers per offence before the first charge could be written.

Sentencing for several offences is **BrB 26:2** rather than an enhancement
table, and it is the one calculation in the suite a prosecutor could be asked to
justify in public.

## Consequences

- Sections 7.7–7.13 are rewritten. Appendix A stays, now as the glossary the
  code is named from rather than as a translation applied afterwards.
- `rms.report.*` becomes `rms.anmalan.*`, `admin.penalcode.edit` becomes
  `admin.brott.edit`, and Appendix B is updated. The access module's internal
  record types (`report`, `case`, `arrest`, `warrant`, `bolo`) are **not**
  renamed: they are the keys grants are stored under, and renaming them would
  orphan every grant already written.
- Two DOJ permission groups exist — `aklagare` and `domare` — and neither
  inherits a police group. A prosecutor is not a senior officer.
- **Swedish is the primary vocabulary, and `en.json` is the harder half.**
  Several terms have no clean English equivalent; where that is so the Swedish
  term is kept with a gloss rather than translated into something that means
  something else. `sv.json` still gets a native-speaker pass before release
  (5.4), but it is no longer the file that can be wrong in the interesting way.
- The host's timezone becomes load-bearing for RB 24:12's local noon. Lua cannot
  resolve an IANA name without a tz database, so the server's own clock is the
  zone that rule is computed in (`frihet/routes.lua` says so at the call site).

## What this does not change

Sections 0–6 and 8–18. The invariants, the architecture, the access model, the
evidence and forensics design and the dispatch module are all procedure-neutral:
a chain of custody and a call card look the same in both systems. The decision
reaches 7.7–7.13 and stops there.

## Alternatives considered

**US workflows with Swedish labels.** Rejected on the RB 24:12 case above: the
labels would have been right and the arithmetic wrong, which is the failure mode
nobody notices until a detention is challenged.

**Defer to M6, when court work lands.** Rejected because M2 is where reports,
arrests and warrants are built, and all three would have had to be rewritten
rather than extended.
