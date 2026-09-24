-- 0031_citation_bill.sql
--
-- The bill a citation sent (spec 7.11, 3.8's billing bridge).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
-- A citation used to be a record and nothing more: the fined player was
-- never asked for the money, and an officer marked it paid by hand if they
-- remembered. Issuing one now sends a real bill through esx_billing, and
-- `bill_id` is that bill's row in esx_billing's own table. The bill leaving
-- that table is how the citation learns it was paid, so `paid_at` is set by
-- the server without anybody pressing a button.
--
-- `bill_label` is kept as sent because withdrawing a bill deletes it by id
-- *and* label: an id alone could name somebody else's bill once esx_billing's
-- table has been truncated and its ids start again.
--
-- NULL means no bill was sent -- billing is off, esx_billing is not started,
-- or the citation names nobody a bill can reach. `ordningsbot.pay` stays for
-- that case, and as the override when a fine is settled some other way.

ALTER TABLE `fpd_ordningsbot`
    ADD COLUMN IF NOT EXISTS `bill_id` BIGINT UNSIGNED NULL
        COMMENT 'esx_billing row id of the bill this citation sent' AFTER `due_at`,
    ADD COLUMN IF NOT EXISTS `bill_label` VARCHAR(191) NULL
        COMMENT 'The label the bill was sent with, as written -- never rebuilt from the locale' AFTER `bill_id`,
    ADD COLUMN IF NOT EXISTS `billed_at` DATETIME(3) NULL AFTER `bill_label`;

CREATE INDEX IF NOT EXISTS `idx_fpd_ordningsbot_bill`
    ON `fpd_ordningsbot` (`status`, `bill_id`);
