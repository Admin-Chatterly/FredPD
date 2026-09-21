-- -----------------------------------------------------------------------------
-- 0014 — the indexes the three new Records screens need
-- -----------------------------------------------------------------------------
--
-- 0013 indexed the lists that existed when it was written. Three of the four
-- screens built since open on a query it did not cover, and each was measured
-- over section 12's 50 ms route budget before this file existed — at 50k rows
-- per table, which 0013's header calls "the size a busy server reaches in a
-- year, not a worst case".
--
-- Measured on MariaDB 10.11, 50k spaning / 50k tvångsmedel / 50k efterlysning /
-- 10k persons, the SQL alone and before access filtering or the audit write:
--
--   | query                                   | before  | after   |
--   | --------------------------------------- | ------- | ------- |
--   | spaning.list, the screen's opening state | 62.4 ms |  1.3 ms |
--   | tvang.list, kind + liveOnly              | 56.4 ms | 13.8 ms |
--   | efterlysning.list, includeCancelled      | 63.4 ms |  0.5 ms |
--   | efterlysning.list, the default live read  | 56.3 ms | 16.6 ms |
--   | IsWanted's person lookup                 |  1.8 ms |  0.2 ms |
--
-- 0013 explicitly decided *against* a spaning index, on the grounds that "the
-- set being sorted is the live one — lookouts actually running — which is tens
-- of rows per agency". That premise was wrong, and the reason is worth keeping:
-- the set the sort has to walk is the set the WHERE clause can *reach with an
-- index*, which was the unresolved set rather than the live one. Nothing marks
-- a lapsed lookout as resolved — `resolved_at` is only written when an officer
-- closes one or when the target is found — so the unresolved set grows without
-- bound while the live set stays at tens of rows. The index below puts the
-- expiry where the range scan can use it, which is what makes the two sets the
-- same size again.
--
-- Idempotent, because CI applies every migration twice (§15).

-- -----------------------------------------------------------------------------
-- Spaningsuppdrag: the list as the screen opens it
-- -----------------------------------------------------------------------------
--
-- `idx_fpd_spaning_agency (agency_id, resolved_at, priority)` could range on
-- the first two columns and then had to read the clustered row for every
-- candidate to test `expires_at` — 45,000 row lookups to return 30 rows.
-- `expires_at` before `priority`: the expiry is what removes rows, and a
-- filesort over a page of live lookouts costs nothing.
ALTER TABLE `fpd_spaning`
    ADD KEY IF NOT EXISTS `idx_fpd_spaning_agency_live`
        (`agency_id`, `resolved_at`, `expires_at`);

-- -----------------------------------------------------------------------------
-- Tvångsmedel: the list with a measure kind selected
-- -----------------------------------------------------------------------------
--
-- `kind` was in no index at all, so filtering by one walked
-- `idx_fpd_tvang_recent` backwards with a clustered lookup per entry. The
-- dangerous pair is `kind` with "in force only", because live measures are a
-- small and recent set: a kind with twelve live matches read all fifty
-- thousand of the agency's rows to find them.
--
-- `created_at` last, so it still serves the ORDER BY once `kind` has been
-- matched — the same shape as `idx_fpd_tvang_recent`, one column deeper.
ALTER TABLE `fpd_tvangsmedel`
    ADD KEY IF NOT EXISTS `idx_fpd_tvang_kind_recent`
        (`agency_id`, `kind`, `created_at`);

-- -----------------------------------------------------------------------------
-- Efterlysning: the history read, and the live list that never filtered expiry
-- -----------------------------------------------------------------------------
--
-- Two problems, one index. The default list filters `cancelled_at IS NULL` and
-- nothing else — a notice that lapsed last March is still read, still joined to
-- `fpd_persons`, still sorted and then drawn as "lapsed". And with "include
-- lifted" ticked the WHERE collapses to the agency alone, which is a filesort
-- and a join per row over every wanted notice the agency has ever issued.
--
-- `expires_at` is nullable on purpose — NULL means "stands until lifted", which
-- is the right default for a prosecutor's decision — and a NULL sorts first in
-- an InnoDB index, so a range on `expires_at > now` would drop exactly the
-- notices that never expire. The repo therefore keeps liveness in
-- `Tvang.isLive` and this index only has to make the rows cheap to reach.
ALTER TABLE `fpd_efterlysning`
    ADD KEY IF NOT EXISTS `idx_fpd_efterlysning_agency_live`
        (`agency_id`, `cancelled_at`, `expires_at`);

-- And the sort, which is the half an index on the filter cannot serve.
--
-- The ORDER BY is `priority ASC, issued_at DESC` — a *mixed direction*, which
-- 0013's header named as the reason it left these lists alone. An all-ascending
-- index cannot serve it, so MariaDB filesorted twenty-five thousand rows to
-- return fifty, whatever else was indexed. A descending column can (MariaDB
-- 10.8+), and with it the history read drops from 63.4 ms to 0.5 ms and the
-- filesort disappears from the plan entirely.
ALTER TABLE `fpd_efterlysning`
    ADD KEY IF NOT EXISTS `idx_fpd_efterlysning_sorted`
        (`agency_id`, `priority`, `issued_at` DESC);

-- -----------------------------------------------------------------------------
-- Persons: the identifier lookup `IsWanted` runs
-- -----------------------------------------------------------------------------
--
-- `uq_fpd_persons_identifier` is `(agency_id, identifier)`, so a WHERE on the
-- identifier alone cannot use it — and `IsWanted(citizenid)` deliberately drops
-- the agency, because the question it answers is whether *anybody* wants this
-- person and a two-force server must not have two blind spots.
--
-- The result was a full scan of `fpd_persons` on an export other resources call
-- per interaction: the same class of defect 0013 fixed for `HasSearchWarrant`,
-- in the export beside it, and missed because the scan is cheap until the name
-- index is large.
--
-- Not unique: the same ESX character may hold a master record in each agency,
-- which is precisely what the export walks.
ALTER TABLE `fpd_persons`
    ADD KEY IF NOT EXISTS `idx_fpd_persons_identifier` (`identifier`);
