# ADR-021: Retention runs inside FXServer

- **Status:** Accepted
- **Date:** 2026-09-24
- **Spec:** 13.3, 11.4, 7.18, 7.13, 7.14
- **Amends:** the scheduler part of 3.7 and 13.3

## Context

Spec 13.3 gave retention to the gateway scheduler. ADR-010 turned the gateway
off by default, so a normal install ran no scheduler at all. Its query log and
plate reads grew without limit. The 30-day ALPR window in 7.18 was a privacy
commitment under 11.4 that nothing kept. Lookouts whose window had run out
(7.13) stayed open. Uploads that were started and never finished (ADR-019) stayed
in the ledger for ever.

## Decision

- **The sweep runs in FXServer**, in `server/modules/retention/`, on a timer.
  The first run is ten minutes after start, so a restart is not also a sweep.
  After that it runs every `retention.intervalMinutes` (default 360, minimum
  15).
- **The sweeps are:**
  - resolving lapsed lookouts;
  - the query log;
  - ALPR reads;
  - stale draft anmälningar;
  - ended surveillance sessions;
  - stop data;
  - uploads that were begun but never committed.
- **Days come from `retention.days`.** Each sweep has a floor: a typo that
  turns 365 into 3 is raised to the floor, not obeyed. `false` turns one sweep
  off. For ALPR reads, the older `cad.alprRetentionDays` applies when
  `retention.days.alprReads` is unset.
- **Every DELETE is bounded.** It deletes 5000 rows at a time, up to 20
  batches per sweep per run. What is left goes on the next run. The large
  tables are swept per agency, so the range uses their
  `(agency_id, time)` index instead of a table scan.
- **The sweeps keep what records depend on:**
  - a draft that has a tilläggsuppgift of its own is kept, because the
    foreign key is RESTRICT;
  - a draft with a pending supervisor return is kept;
  - the surveillance decision (`fpd_hak`) is never swept, only the session
    telemetry.
- **Closed scenes are still not swept.** Their evidence cascades with them;
  see `gateway/src/scheduler/sweeps.ts`.
- **One audit row per run**, `retention.swept`, says what each sweep removed or
  that it failed. No sweep touches `fpd_audit_log` (invariant 11).
- **The gateway is asked only for files.** When it is on, abandoned uploads
  are removed from the media store through `/fx/media/delete`, and each ledger
  row is dropped only after its file is gone. When the gateway is off, there
  were never any files.

## Consequences

- Retention needs no Node, and happens on every install.
- The gateway scheduler's retention sweeps are superseded. Its ALPR default is
  now 30 to match. It should stay off (`FREDPD_SCHEDULER_ENABLED` unset). If
  both run, the deletes are idempotent, so nothing breaks, but the work is
  done twice.
- `admin.retention.edit` still has no screen. The periods are set in
  `config/server.lua`.
