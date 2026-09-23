-- 0026_personnel_loadout.sql
--
-- Equipment loadouts, assignable to an officer and issued or returned
-- automatically with duty (spec 7.22; milestone M6).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
--
-- =============================================================================
-- WHY A LOADOUT IS A NAMED SET OF KEYS, NOT A COPY OF `fpd_personnel_equipment`
-- =============================================================================
--
-- 0017 already lets a supervisor assign one item at a time -- a vest, a
-- radio, a taser -- each its own row with its own serial. That is right for
-- what it tracks (who is holding *this* radio) and wrong for what a
-- supervisor actually wants to hand out at the start of a shift: "the
-- patrol kit". Typing four item rows by hand, every shift, for every
-- officer, is the manual process this migration replaces.
--
-- A loadout is a catalogue entry -- a name and a set of item keys drawn from
-- the same closed list `fpd_personnel_equipment.item_key` already uses
-- (`Personnel.isEquipmentItem`) -- assigned to an officer once
-- (`fpd_officers.loadout_id`), and re-applied every time their duty state
-- changes. It carries no serials and issues nothing by itself: `server/
-- modules/personnel/events.lua` is what turns a duty change into real
-- `fpd_personnel_equipment` rows, diffed against what the officer already
-- holds so a shift that starts with a radio still open does not get a
-- second one.
--
--
-- =============================================================================
-- `ON DELETE SET NULL` ON `fpd_officers.loadout_id`
-- =============================================================================
--
-- Deleting a loadout a supervisor has retired must not delete the officers
-- who happened to be wearing it, nor their equipment history -- the
-- `fpd_personnel_equipment` rows already issued stay exactly as they are,
-- serials and all. It just leaves those officers with no loadout to
-- auto-issue or auto-return next time their duty changes, which reads
-- honestly as "nobody has assigned this officer a kit" rather than as an
-- error.

CREATE TABLE IF NOT EXISTS `fpd_personnel_loadout` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,

    `name`        VARCHAR(191)    NOT NULL COMMENT 'Operator-named, e.g. "Patrol Basic" -- not a locale key',

    `created_by`  VARCHAR(32)     NULL COMMENT 'Discord id',
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `version`     INT UNSIGNED    NOT NULL DEFAULT 1,

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_personnel_loadout_name` (`agency_id`, `name`),
    CONSTRAINT `fk_fpd_personnel_loadout_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_personnel_loadout_name` CHECK (CHAR_LENGTH(TRIM(`name`)) > 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `fpd_personnel_loadout_item` (
    `loadout_id`  BIGINT UNSIGNED NOT NULL,
    `item_key`    VARCHAR(64)     NOT NULL COMMENT 'Locale key, from the same allowlist fpd_personnel_equipment.item_key uses',

    PRIMARY KEY (`loadout_id`, `item_key`),
    CONSTRAINT `fk_fpd_personnel_loadout_item_loadout` FOREIGN KEY (`loadout_id`)
        REFERENCES `fpd_personnel_loadout` (`id`) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

ALTER TABLE `fpd_officers`
    ADD COLUMN IF NOT EXISTS `loadout_id` BIGINT UNSIGNED NULL AFTER `division`;

ALTER TABLE `fpd_officers`
    ADD CONSTRAINT IF NOT EXISTS `fk_fpd_officers_loadout` FOREIGN KEY (`loadout_id`)
        REFERENCES `fpd_personnel_loadout` (`id`) ON DELETE SET NULL;
