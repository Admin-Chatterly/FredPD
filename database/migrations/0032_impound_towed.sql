-- 0032_impound_towed.sql
--
-- Whether an impound took the car off the street (spec 7.15, ADR-016).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
-- An impound from the MDT is a record; one made on the spot through ox_target
-- also deletes the car and marks its owner's garage row as held. Release has
-- to know which it was: putting a car "back in the garage" that is still
-- parked on the street would hand its owner a second copy. So the row says
-- when the car was towed and which exact `owned_vehicles` plate was marked,
-- and only such a row ever writes the garage back on release.

ALTER TABLE `fpd_impound`
    ADD COLUMN IF NOT EXISTS `towed_at` DATETIME(3) NULL
        COMMENT 'Set when the car was deleted from the world by impound.tow',
    ADD COLUMN IF NOT EXISTS `garage_plate` VARCHAR(16) NULL
        COMMENT 'The exact owned_vehicles plate marked held, when one was';

CREATE INDEX IF NOT EXISTS `idx_fpd_impound_garage_plate`
    ON `fpd_impound` (`garage_plate`, `released_at`);
