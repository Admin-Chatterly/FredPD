-- 0037_impound_lot.sql
--
-- The impound lot and what a held car was found with (spec 7.15).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
-- A lot is a placement of kind `impound_lot`, set in the world by an
-- administrator like any terminal (spec 3.10) -- never a coordinate in
-- config. An impound names the lot it stands in, the bay, where its keys are,
-- the state it came in, and what was left inside it: the inventory a front
-- desk reads back to an owner who says something is missing.
--
-- `lot_id` is SET NULL on the placement's deletion: the record of where a car
-- stood outlives the lot being moved, the same way a call outlives its beat.
--
-- A tow puts the car in the lot nearest the officer. The rest is written by
-- whoever does the inventory, and who and when is recorded.

ALTER TABLE `fpd_impound`
    ADD COLUMN IF NOT EXISTS `lot_id` BIGINT UNSIGNED NULL
        COMMENT 'The impound_lot placement the car stands in' AFTER `garage_plate`,
    ADD COLUMN IF NOT EXISTS `bay` VARCHAR(16) NULL AFTER `lot_id`,
    ADD COLUMN IF NOT EXISTS `keys_location` VARCHAR(16) NULL AFTER `bay`,
    ADD COLUMN IF NOT EXISTS `condition_note` VARCHAR(500) NULL AFTER `keys_location`,
    ADD COLUMN IF NOT EXISTS `contents` VARCHAR(1000) NULL AFTER `condition_note`,
    ADD COLUMN IF NOT EXISTS `inventory_by` VARCHAR(32) NULL AFTER `contents`,
    ADD COLUMN IF NOT EXISTS `inventory_at` DATETIME(3) NULL AFTER `inventory_by`;

ALTER TABLE `fpd_impound`
    ADD CONSTRAINT IF NOT EXISTS `ck_fpd_impound_keys` CHECK (`keys_location` IN
        ('in_vehicle', 'lot_safe', 'with_owner', 'none')),
    ADD CONSTRAINT IF NOT EXISTS `fk_fpd_impound_lot` FOREIGN KEY (`lot_id`)
        REFERENCES `fpd_placements` (`id`) ON DELETE SET NULL;
