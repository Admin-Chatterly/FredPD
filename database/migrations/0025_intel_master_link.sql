-- 0025_intel_master_link.sql
--
-- Enforces "at most one intelligence subject per master person record" on
-- `fpd_intel_persons.master_person_id` (spec 10; milestone M2's own header on
-- that column: "master name index record, once M2 exists" -- M2 exists now).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
-- The column has carried no constraint and no code has ever written to it
-- since 0001 -- an analyst's working file and a confirmed identity in the
-- master index were two registers with a bridge nobody had built. This is
-- the write path's other half, spent on `spaning`'s known-associates read
-- (0025 also touches `server/modules/spaning/routes.lua`, not just SQL): a
-- lookout naming a master person now resolves to the analyst's associates
-- for that same person, when one has been linked.
--
-- `NULL` is unaffected by a unique index -- MariaDB does not compare NULLs
-- against each other -- so any number of subjects with no master link yet
-- may coexist; only two subjects claiming the *same* master person collide,
-- which is the one shape `Repo.byMasterPersonId` cannot answer "the" subject
-- for.

ALTER TABLE `fpd_intel_persons`
    ADD UNIQUE KEY IF NOT EXISTS `uq_fpd_intel_persons_master` (`master_person_id`);
