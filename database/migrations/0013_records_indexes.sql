-- 0013_records_indexes.sql
--
-- Indexes for the records half of M2 (spec 7.7-7.13, section 12 budgets).
--
-- Invariant 8: append-only. Never edit this file once it has shipped. These
-- indexes are a separate migration rather than an edit to 0009-0011 for exactly
-- that reason -- the tables they cover have already shipped.
--
--
-- =============================================================================
-- WHY THESE SIX, AND NOT THE ONES 0009-0011 ALREADY HAVE
-- =============================================================================
--
-- The indexes written alongside the tables cover the *filters*. Every list in
-- this half of M2 also has an **order**, and MariaDB can only walk an index in
-- order when the ordering column follows the equality columns in that same
-- index. A `(agency_id, status)` index answers `WHERE agency_id = ? AND status
-- = ?` off the index and then sorts the whole result by hand, which is the
-- `Using filesort` that showed up on every one of these plans.
--
-- Measured against MariaDB 11.4 with 50k tvångsmedel, 50k anmälningar, 50k
-- frihetsberövanden and 20k förundersökningar -- the size a busy server reaches
-- in a year, not a worst case:
--
--   | query                       | before   | after   | plan before        |
--   |-----------------------------|----------|---------|--------------------|
--   | HasSearchWarrant (per door) |  25.3 ms | 0.84 ms | index scan, 49554  |
--   | anmalan.list                | 480.0 ms | 2.67 ms | filesort, 25000    |
--   | frihet.list                 |  83.0 ms | 1.06 ms | filesort, 25000    |
--   | fu.list                     |  16.7 ms | 0.92 ms | filesort, 10000    |
--
-- `Using filesort` is gone from all four plans, and the row estimate on the
-- door scan drops from 49554 to 3.
--
-- The anmälan figure is with `handelseforlopp` still in the list SELECT, which
-- is the other half of that fix and lives in `anmalan/repo.lua`: a list of
-- fifty reports does not need fifty editor documents, and dropping the column
-- takes the same query from 2.67 ms to 0.86 ms. The index is what stops the
-- server reading 25000 of those blobs to find the newest fifty.
--
--
-- =============================================================================
-- THE DOOR SCAN IS THE ONE THAT MATTERS
-- =============================================================================
--
-- `HasSearchWarrant(targetKind, targetId)` (spec 14) is the export a raid or
-- door script calls, and it calls it **per interaction** -- so this is the one
-- query here whose cost lands on a player holding a door open, not on somebody
-- who has chosen to open a list.
--
-- It reads `Repo.forTargetAnyAgency`, which deliberately has no agency in its
-- WHERE clause: a decision by one department does not stop authorising an
-- entry because a second department exists on the server. `idx_fpd_tvang_valid`
-- leads with `agency_id`, so that query could not use it at all and scanned
-- every measure the server had ever recorded. `idx_fpd_tvang_target` is the
-- same index without the agency in front.
--
-- `fpd_spaning` already had this shape right (`idx_fpd_spaning_live` leads with
-- the target, not the agency); this brings `fpd_tvangsmedel` into line with it.
--
--
-- =============================================================================
-- WHAT IS DELIBERATELY NOT HERE
-- =============================================================================
--
--   * **`fpd_efterlysning` and `fpd_spaning` list ordering.** Both order by
--     `priority ASC, issued_at DESC`, and an ascending index cannot serve a
--     mixed-direction sort. The set being sorted is the *live* one -- people
--     actually wanted, lookouts actually running -- which is tens of rows per
--     agency, not tens of thousands, so the filesort is over a page of data and
--     the index would cost more to maintain than it saves.
--   * **`fpd_frihetsberovande` open list.** `Repo.open` filters `status <>
--     'frigiven'`, a range rather than an equality, so no index can carry the
--     ordering past it. The set is everybody currently in custody, which is
--     bounded by the number of cells.
--   * **`anmalan.list` filtered by `mine`.** `idx_fpd_anmalan_author` answers
--     the filter and one officer's reports are few enough to sort.

-- -----------------------------------------------------------------------------
-- Tvångsmedel (7.12)
-- -----------------------------------------------------------------------------

-- The spec 14 export, across every agency.
ALTER TABLE `fpd_tvangsmedel`
    ADD KEY IF NOT EXISTS `idx_fpd_tvang_target` (`target_kind`, `target_id`, `valid_until`);

-- `Repo.list`: WHERE agency_id = ? ORDER BY created_at DESC.
ALTER TABLE `fpd_tvangsmedel`
    ADD KEY IF NOT EXISTS `idx_fpd_tvang_recent` (`agency_id`, `created_at`);

-- -----------------------------------------------------------------------------
-- Anmälan (7.7)
-- -----------------------------------------------------------------------------

-- The default Records list: WHERE agency_id = ? AND parent_id IS NULL
-- ORDER BY created_at DESC.
--
-- `parent_id` sits in the middle because `IS NULL` is an equality as far as an
-- index is concerned -- tilläggsuppgifter are hidden from the top-level list by
-- default (they belong under their parent), so the predicate is on nearly every
-- call and leaving it out would put the sort back.
ALTER TABLE `fpd_anmalan`
    ADD KEY IF NOT EXISTS `idx_fpd_anmalan_recent` (`agency_id`, `parent_id`, `created_at`);

-- The same list with a status filter, which is how a supervisor finds what is
-- waiting for approval. `parent_id IS NULL` becomes a filter applied as the
-- index is walked, which costs a few extra row reads and keeps the ordering.
ALTER TABLE `fpd_anmalan`
    ADD KEY IF NOT EXISTS `idx_fpd_anmalan_status_recent` (`agency_id`, `status`, `created_at`);

-- -----------------------------------------------------------------------------
-- Förundersökning (7.8)
-- -----------------------------------------------------------------------------

ALTER TABLE `fpd_forundersokning`
    ADD KEY IF NOT EXISTS `idx_fpd_fu_recent` (`agency_id`, `opened_at`);

-- -----------------------------------------------------------------------------
-- Frihetsberövande (7.9)
-- -----------------------------------------------------------------------------

-- `Repo.list` -- the history, not `Repo.open`. A detention is never deleted, so
-- this table only grows, and it is the one a defence lawyer's question is
-- answered from months later.
ALTER TABLE `fpd_frihetsberovande`
    ADD KEY IF NOT EXISTS `idx_fpd_frihet_recent` (`agency_id`, `created_at`);
