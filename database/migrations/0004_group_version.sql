-- 0004_group_version.sql
--
-- Optimistic locking for the permission group editor (spec 3.5, 4.3).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
-- `fpd_permission_groups` was the only editable record in the schema without a
-- `version` column. Every other one -- persons, organisations, notes, cases --
-- has carried one since 0001, and the routes that write them refuse a stale
-- write with `conflict`. The group editor had nothing, so two administrators
-- with the screen open silently overwrote each other.
--
-- Silent is the operative word, and it is why this is not cosmetic. An update
-- REPLACES the group's permission set rather than merging into it, so the
-- loser's grants do not survive anywhere: not in the group, and not in the
-- audit trail, where the diff reads as though the winner had deliberately
-- removed them. A revoked permission that nobody revoked is the worst kind of
-- entry to find in an audit log a month later.
--
-- The column does double duty. Beyond guarding its own row, `admin`'s version
-- is taken as the write lock for the permission model as a whole: an edit
-- anywhere in an inheritance chain bumps it, so a second editor that read the
-- chain before that bump is refused rather than committing a state neither
-- author ever saw. That is the check-then-write gap the group routes could not
-- otherwise close, because the escalation check reads the whole model and the
-- write lands one row at a time.
--
-- `IF NOT EXISTS` because a server that took 0.2.0 and ran the seed by hand may
-- already have the column; MariaDB 10.0+ supports it on ADD COLUMN.

ALTER TABLE `fpd_permission_groups`
    ADD COLUMN IF NOT EXISTS `version` INT UNSIGNED NOT NULL DEFAULT 1
        COMMENT 'Optimistic lock. `admin`s row also locks the model as a whole';
