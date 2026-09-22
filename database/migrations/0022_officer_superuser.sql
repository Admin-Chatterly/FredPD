-- 0022_officer_superuser.sql
--
-- A permanent superuser flag on the officer row (spec 4.3, invariant 2).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
-- `server/modules/admin/superuser.lua`'s console command originally granted
-- superuser by mapping a Discord role to the `superuser` permission group
-- (`database/seeds/0003_superuser.sql`), which is checked the same way every
-- other grant is: against a live Discord role snapshot. That is right for an
-- ordinary grant and wrong for a recovery path -- the whole point of
-- `fredpd_superuser` is being available the day something else is broken,
-- and "something else" includes Discord itself: no bot configured yet on a
-- development server, a token that has expired, or a guild the server can no
-- longer reach. A recovery grant that depends on the thing most likely to be
-- broken is not a recovery grant.
--
-- This column is what makes it independent of that: a flag `Session.open`
-- reads once per session open and honours directly, in place of deriving
-- permissions from Discord roles at all. Set from the console, it survives a
-- Discord outage, a revoked role, and a `fpd_discord_members` table that has
-- never been populated because no bot has ever run against this server.

ALTER TABLE `fpd_officers`
    ADD COLUMN IF NOT EXISTS `superuser` TINYINT(1) NOT NULL DEFAULT 0
        COMMENT 'Permanent recovery grant from fredpd_superuser (console only). Independent of Discord.';
