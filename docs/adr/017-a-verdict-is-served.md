# ADR-017: A verdict is served in the game

- **Status:** Accepted
- **Date:** 2026-09-24
- **Spec:** 7.20, 7.21, 3.8

## Context

A domare could enter "guilty, 18 months" and nothing followed. An åtal named an
investigation and charges but not a person, so there was nobody to send
anywhere, and spec 7.20 recorded the jail handoff as not built. The owner runs
p_policejob, whose built-in jail is started through a documented server export,
`JailPlayer(source, { player, jail, fine, reason })`.

## Decision

- **An åtal names its tilltalade** (`fpd_atal.person_id`, migration 0033).
  - The åklagare chooses them from the misstänkta on the investigation's
    reports that the åklagare may read. The server refuses anyone else, and a
    sealed report's link to a person is never used.
  - When the whole investigation names exactly one misstänkt and it is visible,
    that person is the tilltalade.
  - When it names several, choosing one is required.
  - The bare id never leaves the server; the screen gets `defendant` only when
    the reader may read the person.
- **The sentence is converted once**, when the verdict is entered:
  - one month is `jail.minutesPerMonth` game minutes;
  - the result is clamped to `minMinutes`–`maxMinutes`;
  - livstid is served as `maxMinutes`;
  - the result is stored as `jail_minutes`, so a later config change never
    moves a sentence already handed down.

  Only guilty and plea verdicts with months or livstid are custodial.
- **`fredpd:sentenced` hands the tilltalade to the jail** through the
  policejob bridge. The export is config (`jail.resource`, `jail.export`), so a
  different jail with the same call needs no code change.
  - When the tilltalade is online, the jail call happens at once, with the domare
    as the jailer.
  - When they are not online, it happens when their character next loads, with
    themselves as the source.
  - A sentence is claimed (`jailed_at`) before the call and released if the call
    fails. Two logins in a row cannot jail twice, and a jail that was down does
    not lose the sentence.
- **The officers who worked the case are told the verdict**: those who made an
  arrest in it, wrote its reports or led it. Each is told only if they may know
  of the åtal.

## Consequences

- A trial ends in the cell.
- The unit of p_policejob's `jail` value is not stated in its public docs.
  Minutes is assumed, and `minutesPerMonth` adjusts it.
- Who is physically jailed is decided by the person record's ESX identifier,
  which an officer links when the record is created. Misusing that link to jail
  the wrong character still needs an officer, an åklagare and a domare, and
  each step is audited.
- A jail that answers `false` is treated as not having jailed. The sentence
  stays unserved for the next attempt.
- Time served and release stay with the jail resource. FredPD records when the
  sentence was handed over, not when it ended.

## Alternatives considered

- **Jail on booking.** Booking is custody before any decision: häktning, not a
  sentence. Jailing then would punish before the court has ruled.
- **Let the domare press "send to jail".** One more button after a verdict that
  already says what should happen. The owner asked for less of that.
