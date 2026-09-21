-- 0017_personnel.sql
--
-- Personnel: roster detail, shift log, equipment assignment, certifications
-- and the disciplinary file (spec 7.22-7.24; milestone M6).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
--
-- =============================================================================
-- WHY THIS EXTENDS `fpd_officers` RATHER THAN REPLACING IT
-- =============================================================================
--
-- 0001 already created the roster: one row per Discord id who may open
-- FredPD, with the bound ESX character and a callsign. That is the personnel
-- record -- this migration adds the columns command staff actually asked for
-- (badge number, division, hire date) with `ADD COLUMN IF NOT EXISTS`, the
-- same idempotent idiom 0014 used for a key. A second roster table would be a
-- second place "who is on the department" lives, and `fpd_officers.discord_id`
-- is already the join every session reads.
--
--
-- =============================================================================
-- WHY THERE IS NO RANK COLUMN, AND NO ROLE-CHANGE ROUTE
-- =============================================================================
--
-- The original sketch of this milestone (see the plan) had hire/promote/demote
-- write Discord roles through the gateway bridge. ADR-010 landed first and
-- settled it the other way: FXServer only ever *reads* the guild (invariant 2
-- read literally -- Discord roles are the only permission source, and a
-- resource that could also grant them would be the source contradicting
-- itself). A department's rank structure is whatever Discord roles it maps to
-- permission groups from the MDT already (spec 7.30); this module displays
-- that mapping and never writes to Discord. "Promote" in this screen means
-- changing `division` or reactivating a roster row, not a role.
--
--
-- =============================================================================
-- THE DISCIPLINARY FILE
-- =============================================================================
--
-- `fpd_personnel_discipline` is written against the record-type/classification
-- machinery `access/repo.lua` already allowlists (`ia_case`), with
-- `compartment = 'internal_affairs'`, which ships stubbed for everyone until
-- an operator configures who may see it (spec 4.5) -- the same closed-by-
-- default posture `court`'s restricted åtal rows already exercise.

-- -----------------------------------------------------------------------------
-- Roster detail
-- -----------------------------------------------------------------------------

ALTER TABLE `fpd_officers`
    ADD COLUMN IF NOT EXISTS `badge_number` VARCHAR(16) NULL AFTER `callsign`,
    ADD COLUMN IF NOT EXISTS `division` VARCHAR(64) NULL AFTER `badge_number`,
    ADD COLUMN IF NOT EXISTS `hire_date` DATE NULL AFTER `division`;

ALTER TABLE `fpd_officers`
    ADD UNIQUE KEY IF NOT EXISTS `uq_fpd_officers_badge` (`agency_id`, `badge_number`);

-- -----------------------------------------------------------------------------
-- Shift log
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_personnel_shift_log` (
    `id`           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`    VARCHAR(32)     NOT NULL,
    `officer_id`   BIGINT UNSIGNED NOT NULL,
    `callsign`     VARCHAR(32)     NULL COMMENT 'The callsign held for this shift, which may differ from the roster''s current one',
    `started_at`   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `ended_at`     DATETIME(3)     NULL,

    PRIMARY KEY (`id`),
    KEY `idx_fpd_shift_officer` (`officer_id`, `started_at`),
    KEY `idx_fpd_shift_agency_open` (`agency_id`, `ended_at`),
    CONSTRAINT `fk_fpd_shift_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_shift_officer` FOREIGN KEY (`officer_id`)
        REFERENCES `fpd_officers` (`id`) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Equipment assignment
--
-- `firearm_id` is nullable: most assigned equipment (a vest, a radio, a unit
-- laptop) is not in the firearms registry at all, and forcing every row
-- through that table would mean inventing catalogue rows for things that are
-- not firearms. When it *is* a firearm, the FK ties the assignment to the
-- same registry `rms.firearm.*` already governs, rather than a second free-
-- text serial number that could silently drift from it.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_personnel_equipment` (
    `id`           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`    VARCHAR(32)     NOT NULL,
    `officer_id`   BIGINT UNSIGNED NOT NULL,
    `firearm_id`   BIGINT UNSIGNED NULL,
    `item_key`     VARCHAR(64)     NOT NULL COMMENT 'Locale key, e.g. equipment.item.vest',
    `serial`       VARCHAR(64)     NULL,
    `assigned_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `assigned_by`  VARCHAR(32)     NOT NULL,
    `returned_at`  DATETIME(3)     NULL,

    PRIMARY KEY (`id`),
    KEY `idx_fpd_equipment_officer_open` (`officer_id`, `returned_at`),
    KEY `idx_fpd_equipment_firearm` (`firearm_id`),
    CONSTRAINT `fk_fpd_equipment_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_equipment_officer` FOREIGN KEY (`officer_id`)
        REFERENCES `fpd_officers` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_equipment_firearm` FOREIGN KEY (`firearm_id`)
        REFERENCES `fpd_firearms` (`id`) ON DELETE RESTRICT
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Certifications, usable as context conditions (spec 7.23)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_personnel_certification` (
    `id`           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`    VARCHAR(32)     NOT NULL,
    `officer_id`   BIGINT UNSIGNED NOT NULL,
    `cert_key`     VARCHAR(64)     NOT NULL COMMENT 'Locale key, e.g. cert.firearms_instructor',
    `issued_at`    DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `issued_by`    VARCHAR(32)     NOT NULL,
    `expires_at`   DATETIME(3)     NULL COMMENT 'NULL means it does not expire',
    `revoked_at`   DATETIME(3)     NULL,
    `revoked_by`   VARCHAR(32)     NULL,

    PRIMARY KEY (`id`),
    KEY `idx_fpd_cert_officer` (`officer_id`, `cert_key`),
    CONSTRAINT `fk_fpd_cert_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_cert_officer` FOREIGN KEY (`officer_id`)
        REFERENCES `fpd_officers` (`id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_cert_revoked` CHECK (
        (`revoked_at` IS NULL AND `revoked_by` IS NULL)
        OR (`revoked_at` IS NOT NULL AND `revoked_by` IS NOT NULL))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- The disciplinary file (spec 7.24)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_personnel_discipline` (
    `id`             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`      VARCHAR(32)     NOT NULL,
    `number`         VARCHAR(32)     NOT NULL COMMENT 'Counter kind `ia_case` (Appendix D)',
    `officer_id`     BIGINT UNSIGNED NOT NULL,
    `category`       VARCHAR(64)     NOT NULL COMMENT 'Locale key',
    `summary`        VARCHAR(2000)   NOT NULL,
    `classification` VARCHAR(16)     NOT NULL DEFAULT 'restricted',
    `compartment`    VARCHAR(32)     NOT NULL DEFAULT 'internal_affairs',
    `created_by`     VARCHAR(32)     NOT NULL,
    `created_at`     DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `closed_at`      DATETIME(3)     NULL,
    `outcome_key`    VARCHAR(64)     NULL COMMENT 'Locale key, set when closed',
    `version`        INT UNSIGNED    NOT NULL DEFAULT 1,

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_discipline_number` (`agency_id`, `number`),
    KEY `idx_fpd_discipline_officer` (`officer_id`),
    CONSTRAINT `fk_fpd_discipline_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_discipline_officer` FOREIGN KEY (`officer_id`)
        REFERENCES `fpd_officers` (`id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_discipline_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret')),
    CONSTRAINT `ck_fpd_discipline_closed` CHECK (
        (`closed_at` IS NULL AND `outcome_key` IS NULL)
        OR (`closed_at` IS NOT NULL AND `outcome_key` IS NOT NULL)),
    CONSTRAINT `ck_fpd_discipline_number` CHECK (CHAR_LENGTH(TRIM(`number`)) > 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;
