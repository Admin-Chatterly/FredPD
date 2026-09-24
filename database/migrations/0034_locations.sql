-- 0034_locations.sql
--
-- Locations and premises (spec 7.6): the address index, the hazards an officer
-- should know before walking up to a door, and who holds the keys.
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
-- 0007 left the call card a place to show premise hazards "when that table
-- exists". This is that table, and the address it hangs off.
--
-- **A location is a record with a position, not a placement.** Placements
-- (3.10) are the suite's own furniture -- terminals, lockers, benches -- and
-- are configured by an administrator. An address is police data: an officer
-- registers it where they stand (the server reads the position off their
-- ped) or types it from a report, and it carries a classification like every
-- other record. The position is optional for the same reason a call's is: a
-- premise known only by its street address is still a premise.
--
-- `radius` is how far from the point a call still counts as "at" the premise:
-- a car park is larger than a flat.

CREATE TABLE IF NOT EXISTS `fpd_locations` (
    `id`             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`      VARCHAR(32)     NOT NULL,
    `label`          VARCHAR(191)    NOT NULL COMMENT 'The address as written: 12 Alta Street',
    `kind`           VARCHAR(16)     NOT NULL DEFAULT 'residence',
    `x`              DOUBLE          NULL,
    `y`              DOUBLE          NULL,
    `z`              DOUBLE          NULL,
    `radius`         SMALLINT UNSIGNED NOT NULL DEFAULT 30 COMMENT 'Metres around the point that count as this premise',
    `notes`          VARCHAR(500)    NULL,
    `classification` VARCHAR(16)     NOT NULL DEFAULT 'internal',
    `created_by`     VARCHAR(32)     NOT NULL,
    `created_at`     DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_by`     VARCHAR(32)     NULL,
    `updated_at`     DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    `version`        INT UNSIGNED    NOT NULL DEFAULT 1,

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_locations_id_agency` (`id`, `agency_id`),
    KEY `idx_fpd_locations_label` (`agency_id`, `label`),
    KEY `idx_fpd_locations_position` (`agency_id`, `x`, `y`),
    CONSTRAINT `fk_fpd_locations_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_locations_kind` CHECK (`kind` IN
        ('residence', 'business', 'public', 'industrial', 'other')),
    CONSTRAINT `ck_fpd_locations_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret')),
    CONSTRAINT `ck_fpd_locations_label` CHECK (CHAR_LENGTH(TRIM(`label`)) > 0),
    -- A position is all three coordinates or none of them.
    CONSTRAINT `ck_fpd_locations_position` CHECK (
        (`x` IS NULL AND `y` IS NULL AND `z` IS NULL)
        OR (`x` IS NOT NULL AND `y` IS NOT NULL AND `z` IS NOT NULL))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- A hazard is a warning, not a verdict: "a dog that bites", "weapons kept in
-- the house", "has attacked officers before". It is written by whoever met
-- it, may expire, and is cancelled rather than deleted, so the card can say
-- who flagged it and when, and a cancelled one is still there to be audited.
CREATE TABLE IF NOT EXISTS `fpd_location_hazards` (
    `id`           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `location_id`  BIGINT UNSIGNED NOT NULL,
    `agency_id`    VARCHAR(32)     NOT NULL,
    `kind`         VARCHAR(24)     NOT NULL,
    `note`         VARCHAR(255)    NULL,
    `expires_at`   DATETIME(3)     NULL,
    `created_by`   VARCHAR(32)     NOT NULL,
    `created_at`   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `cancelled_by` VARCHAR(32)     NULL,
    `cancelled_at` DATETIME(3)     NULL,

    PRIMARY KEY (`id`),
    KEY `idx_fpd_location_hazards_live` (`location_id`, `cancelled_at`, `expires_at`),
    CONSTRAINT `fk_fpd_location_hazards_location` FOREIGN KEY (`location_id`, `agency_id`)
        REFERENCES `fpd_locations` (`id`, `agency_id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_location_hazards_kind` CHECK (`kind` IN
        ('dog', 'weapons', 'hostile', 'violent_history', 'medical', 'infectious',
         'children', 'hazardous_materials', 'other')),
    CONSTRAINT `ck_fpd_location_hazards_cancelled` CHECK (
        (`cancelled_at` IS NULL AND `cancelled_by` IS NULL)
        OR (`cancelled_at` IS NOT NULL AND `cancelled_by` IS NOT NULL))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Who to call at three in the morning when the alarm is going: owners,
-- tenants and keyholders, as person records -- never a name typed here, so
-- the person's own access control and their phone number on file apply.
CREATE TABLE IF NOT EXISTS `fpd_location_keyholders` (
    `location_id` BIGINT UNSIGNED NOT NULL,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `person_id`   BIGINT UNSIGNED NOT NULL,
    `role`        VARCHAR(16)     NOT NULL,
    `created_by`  VARCHAR(32)     NOT NULL,
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`location_id`, `person_id`),
    KEY `idx_fpd_location_keyholders_person` (`agency_id`, `person_id`),
    CONSTRAINT `fk_fpd_location_keyholders_location` FOREIGN KEY (`location_id`, `agency_id`)
        REFERENCES `fpd_locations` (`id`, `agency_id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_location_keyholders_person` FOREIGN KEY (`person_id`)
        REFERENCES `fpd_persons` (`id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_location_keyholders_role` CHECK (`role` IN
        ('owner', 'tenant', 'keyholder', 'manager', 'employee'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;
