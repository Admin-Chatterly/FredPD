-- 0036_tariff_licence.sql
--
-- The ordningsbot tariff gets an editor, a free-text label, and licence
-- points (spec 7.11, ADR-018).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
-- `label`: a line written by the agency's own command. The shipped defaults
-- are named by a locale key (`label_key`) so they read in both languages; a
-- line an agency adds itself is named in its own words and carries the
-- sentinel key `ordningsbot.tariff.custom`, which is never shown when a label
-- is present. It is data an administrator wrote, the same standing a
-- narrative has, not user-interface text (invariant 6).
--
-- `licence_points`: what one citation under this version adds to the named
-- person's driving licence. Written on the version, so it is as immutable as
-- the amount beside it. A licence's standing is summed from citations still
-- `issued` or `paid` inside a rolling window (config/server.lua), never
-- stored -- the same "computed from dates" shape as the payment status and
-- the impound fee. A voided or contested citation stops counting the moment
-- it moves. Points land only on a person the citation names; a fine sent to a
-- vehicle's keeper does not say who was driving.

ALTER TABLE `fpd_ordningsbot_tariff`
    ADD COLUMN IF NOT EXISTS `label` VARCHAR(120) NULL
        COMMENT 'A line the agency wrote itself; NULL for a shipped line named by label_key' AFTER `label_key`,
    ADD COLUMN IF NOT EXISTS `licence_points` TINYINT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'Points one citation adds to the named person''s licence' AFTER `amount`;

ALTER TABLE `fpd_ordningsbot_tariff`
    ADD CONSTRAINT IF NOT EXISTS `ck_fpd_ordningsbot_tariff_points` CHECK (`licence_points` <= 20);

-- The licence sum: a person's citations inside the window.
CREATE INDEX IF NOT EXISTS `idx_fpd_ordningsbot_person`
    ON `fpd_ordningsbot` (`agency_id`, `person_id`, `status`, `issued_at`);
