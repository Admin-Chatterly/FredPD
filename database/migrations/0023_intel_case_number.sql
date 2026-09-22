-- 0023_intel_case_number.sql
--
-- A generated number for an intelligence case (Appendix D, spec 10).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
-- Every other case-like record in the suite already draws a number from
-- `fpd_counters` under the row lock `server/core/counters.lua` describes --
-- a förundersökning is `{AGENCY}-C{YY}-{#####}` (counter kind `case`), a
-- report is `{AGENCY}-{YY}-{######}` (kind `report`). `fpd_intel_cases` was
-- the one exception: an analyst's working case file, identified only by its
-- auto-increment `id`, because Appendix D's `case` row already names the FU
-- and reusing that kind here would put two different records' numbers in one
-- sequence -- unreadable back to either.
--
-- This is its own counter kind, `intel_case`, so the format is `{AGENCY}-IC{YY}-{#####}`
-- (e.g. `LSPD-IC26-00007`) -- distinct from the FU's `-C` on sight, the same
-- way a citation's `-T` and impound's bare `I` stay apart from everything
-- else in Appendix D.
--
-- Nullable rather than backfilled: a case opened before this migration has no
-- number to allocate one from, and fabricating one out of the row's `id`
-- would be a number nobody actually drew under the counter lock. It reads as
-- "no number assigned" until an administrator's tooling gives it one, or
-- forever, if none ever does -- both are honest, and neither is a guess.

ALTER TABLE `fpd_intel_cases`
    ADD COLUMN IF NOT EXISTS `number` VARCHAR(24) NULL
        COMMENT 'Counter kind intel_case: {AGENCY}-IC{YY}-{#####}. NULL on a case opened before this column existed.',
    ADD UNIQUE KEY IF NOT EXISTS `uq_fpd_intel_cases_number` (`agency_id`, `number`);
