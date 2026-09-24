# ADR-026: The population register in search

- **Status:** Accepted
- **Date:** 2026-09-24
- **Spec:** 7.2, 4.5, 11.4; invariants 1 and 4

## Context

Person and vehicle searches read only FredPD's own registers. A character
that no officer had run a field check on had no record, so a search could not
find it. That included the officer's own character: "search does not find my
own name".

The first fix listed the framework's characters and owned cars that had no
record, and let any holder of `rms.person.view` open one. The security review
found four problems with it:

- **Read-only roles could create records.** `rms.*.view` is held by the
  read-only roles, åklagare and domare. Twenty opens a minute also let
  anyone create records in bulk.
- **The framework's identifier reached the NUI.** An identifier is a
  player's licence, and 11.4 keeps licences to administrators. Opening also
  accepted any identifier the client had learned elsewhere.
- **LIKE wildcards passed the two-character minimum.** A term like `__`
  matched every row of a table with no agency scope.
- **Leaving a record out is itself a signal.** A citizen who appears neither
  among the results nor in the population list has a record the reader may not
  see.

## Decision

- **A permission of its own: `population.search`.** It is seeded to `patrol`,
  and supervisors inherit it. It gates both the list and opening from it. The
  read-only roles do not get it. Opening also requires duty and is limited to
  five a minute, the same shape as `field.person.resolve`.
- **References, not keys.** A suggestion carries a short reference. The server
  keeps which key it offered to which officer, for ten minutes, with at most
  forty live per officer. Opening takes only the reference and re-reads the
  framework itself. An identifier never reaches the client, and a key learned
  anywhere else cannot be tried.
- **Names only, wildcards stripped.** A term matches first and last names and
  never the identifier column. `%`, `_` and `\` are removed before the length
  check.
- **Keys on file are never offered,** whatever that record's access. Opening
  answers through the record's own access-checked read. A vehicle's keeper is
  linked only when the officer may read the keeper's record.
- **Accepted: the gap is visible.** As long as the whole population is listed,
  a record tied to a framework character cannot be fully hidden from someone
  who knows the name: its absence from both lists says it exists. Supervisors
  already had the same signal through the ESX prefill search
  (`esx.character.search`, `rms.person.edit`). This decision widens it to
  patrol, deliberately and under its own key. An agency that runs records
  hidden from patrol (`sources`, sealed records) can withhold
  `population.search` from patrol, and nothing else changes.

## Consequences

- Patrol finds everyone the game knows about. Opening one creates the record
  once, audited as `person.created` with `source = population_register`.
- The protection around a hidden record is the permission, not the list. That
  holds because the key can be withheld per group.
