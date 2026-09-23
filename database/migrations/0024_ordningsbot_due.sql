-- 0024_ordningsbot_due.sql
--
-- A payment due date on a citation, and the overdue state read off it
-- (spec 7.11).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
-- 0019 gave a citation exactly four states -- issued, paid, contested, void
-- -- and left "has anyone actually paid this yet" to be read off `status`
-- alone. That collapses two different facts into one: an `issued` citation
-- from an hour ago and one from three months ago render identically, with
-- nothing on the record saying the second one is overdue. `due_at` is what
-- lets `ordningsbot/service.lua` tell them apart -- the same "computed from
-- dates, not timers" approach `impound/service.lua`'s `Impound.feeOwed`
-- already takes for the impound fee, applied here to a status instead of a
-- fee. There is still no fifth database status: `overdue` is derived at read
-- time from `status` and `due_at` together, never written to the column --
-- `ck_fpd_ordningsbot_status` is untouched by this migration, and
-- `Ordningsbot.mayTransition` still only knows the four it always has.
--
-- Written once, at issue time, from `config.server.ordningsbot.paymentWindowDays`
-- as it stood *then* -- never re-derived from whatever the config says today.
-- A later change to the payment window must not silently move the deadline on
-- a citation already handed to somebody, which is the identical argument
-- 0019's own header makes for citing an immutable tariff version rather than
-- "the current tariff".
--
-- Backfilled below for citations issued before this column existed, using the
-- same 30-day default the config ships with -- the closest honest answer
-- available, since no earlier row recorded what window was actually in effect
-- when it was issued.

ALTER TABLE `fpd_ordningsbot`
    ADD COLUMN IF NOT EXISTS `due_at` DATETIME(3) NULL
        COMMENT 'issued_at + the payment window in effect at issue time (config.server.ordningsbot.paymentWindowDays)';

UPDATE `fpd_ordningsbot`
   SET `due_at` = DATE_ADD(`issued_at`, INTERVAL 30 DAY)
 WHERE `due_at` IS NULL;

ALTER TABLE `fpd_ordningsbot`
    MODIFY COLUMN `due_at` DATETIME(3) NOT NULL;
