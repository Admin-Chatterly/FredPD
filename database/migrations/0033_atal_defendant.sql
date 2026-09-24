-- 0033_atal_defendant.sql
--
-- Who an åtal is against, and whether their sentence has been served out in
-- the world (spec 7.20, ADR-017).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
-- An åtal named an investigation and a list of charges, but not a person, so
-- a guilty verdict could not reach anyone: the domare entered "12 months" and
-- nothing happened. `person_id` is the tilltalade, chosen by the åklagare from
-- the investigation's own misstänkta and checked on the server.
--
-- `jail_minutes` is the sentence as the jail will serve it, fixed when the
-- verdict is entered (a later change to the conversion never moves one already
-- handed down). `jailed_at` is when it was handed to the jail -- NULL while the
-- person has not been online to receive it, which is what the join-time check
-- looks for.

ALTER TABLE `fpd_atal`
    ADD COLUMN IF NOT EXISTS `person_id` BIGINT UNSIGNED NULL
        COMMENT 'The tilltalade; one of the FU''s misstänkta' AFTER `fu_id`,
    ADD COLUMN IF NOT EXISTS `jail_minutes` INT UNSIGNED NULL
        COMMENT 'The custodial sentence in jail minutes, fixed at the verdict' AFTER `sentence_livstid`,
    ADD COLUMN IF NOT EXISTS `jailed_at` DATETIME(3) NULL
        COMMENT 'When the sentence was handed to the jail' AFTER `jail_minutes`;

ALTER TABLE `fpd_atal`
    ADD CONSTRAINT IF NOT EXISTS `fk_fpd_atal_person` FOREIGN KEY (`person_id`)
        REFERENCES `fpd_persons` (`id`) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS `idx_fpd_atal_jail`
    ON `fpd_atal` (`person_id`, `jailed_at`);
