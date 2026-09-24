-- 0035_field_interviews.sql
--
-- Field interview cards and stop data (spec 7.14).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
-- A field interview card (sv: fältanteckning) is the note an officer makes
-- about somebody met on patrol who was not arrested or cited: who, where,
-- why they were spoken to, who they were with, and what they were driving.
-- It is intelligence, not an accusation, and carries a classification like
-- every other record.
--
-- A stop (sv: kontroll) is the data row every traffic or pedestrian stop
-- leaves: why it was made, whether anything was searched, and how it ended.
-- It feeds statistics (7.27) and says nothing a stop's own records do not.
--
-- Both take their position from the officer's ped, on the server, and link
-- the call the officer was on at the time when there was one.

CREATE TABLE IF NOT EXISTS `fpd_fi_cards` (
    `id`             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`      VARCHAR(32)     NOT NULL,
    `person_id`      BIGINT UNSIGNED NULL,
    `vehicle_id`     BIGINT UNSIGNED NULL,
    `call_id`        BIGINT UNSIGNED NULL,
    `reason`         VARCHAR(24)     NOT NULL,
    `narrative`      VARCHAR(1000)   NULL,
    `location_text`  VARCHAR(191)    NULL,
    `x`              DOUBLE          NULL,
    `y`              DOUBLE          NULL,
    `z`              DOUBLE          NULL,
    `classification` VARCHAR(16)     NOT NULL DEFAULT 'internal',
    `created_by`     VARCHAR(32)     NOT NULL,
    `created_at`     DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_fi_cards_id_agency` (`id`, `agency_id`),
    KEY `idx_fpd_fi_cards_person` (`agency_id`, `person_id`, `created_at`),
    KEY `idx_fpd_fi_cards_vehicle` (`agency_id`, `vehicle_id`, `created_at`),
    KEY `idx_fpd_fi_cards_created` (`agency_id`, `created_at`),
    CONSTRAINT `fk_fpd_fi_cards_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_fi_cards_person` FOREIGN KEY (`person_id`)
        REFERENCES `fpd_persons` (`id`) ON DELETE SET NULL,
    CONSTRAINT `fk_fpd_fi_cards_vehicle` FOREIGN KEY (`vehicle_id`)
        REFERENCES `fpd_vehicles` (`id`) ON DELETE SET NULL,
    CONSTRAINT `ck_fpd_fi_cards_reason` CHECK (`reason` IN
        ('suspicious_behaviour', 'matches_description', 'known_associate', 'area_check',
         'gang_activity', 'drug_activity', 'other')),
    CONSTRAINT `ck_fpd_fi_cards_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret')),
    -- A card about nobody and nothing is not a card.
    CONSTRAINT `ck_fpd_fi_cards_subject` CHECK (`person_id` IS NOT NULL OR `vehicle_id` IS NOT NULL
        OR `narrative` IS NOT NULL)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Who the subject was with. Person records, never typed names, so each
-- associate's own access control applies.
CREATE TABLE IF NOT EXISTS `fpd_fi_associates` (
    `fi_id`     BIGINT UNSIGNED NOT NULL,
    `person_id` BIGINT UNSIGNED NOT NULL,

    PRIMARY KEY (`fi_id`, `person_id`),
    KEY `idx_fpd_fi_associates_person` (`person_id`),
    CONSTRAINT `fk_fpd_fi_associates_card` FOREIGN KEY (`fi_id`)
        REFERENCES `fpd_fi_cards` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_fi_associates_person` FOREIGN KEY (`person_id`)
        REFERENCES `fpd_persons` (`id`) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `fpd_stops` (
    `id`             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`      VARCHAR(32)     NOT NULL,
    `kind`           VARCHAR(16)     NOT NULL,
    `reason`         VARCHAR(24)     NOT NULL,
    `search`         VARCHAR(24)     NOT NULL,
    `result`         VARCHAR(16)     NOT NULL,
    `person_id`      BIGINT UNSIGNED NULL,
    `vehicle_id`     BIGINT UNSIGNED NULL,
    `call_id`        BIGINT UNSIGNED NULL,
    `x`              DOUBLE          NULL,
    `y`              DOUBLE          NULL,
    `z`              DOUBLE          NULL,
    `classification` VARCHAR(16)     NOT NULL DEFAULT 'internal',
    `created_by`     VARCHAR(32)     NOT NULL,
    `created_at`     DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_stops_id_agency` (`id`, `agency_id`),
    KEY `idx_fpd_stops_created` (`agency_id`, `created_at`),
    KEY `idx_fpd_stops_officer` (`agency_id`, `created_by`, `created_at`),
    CONSTRAINT `fk_fpd_stops_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_stops_person` FOREIGN KEY (`person_id`)
        REFERENCES `fpd_persons` (`id`) ON DELETE SET NULL,
    CONSTRAINT `fk_fpd_stops_vehicle` FOREIGN KEY (`vehicle_id`)
        REFERENCES `fpd_vehicles` (`id`) ON DELETE SET NULL,
    CONSTRAINT `ck_fpd_stops_kind` CHECK (`kind` IN ('traffic', 'pedestrian')),
    CONSTRAINT `ck_fpd_stops_reason` CHECK (`reason` IN
        ('traffic_violation', 'equipment_fault', 'suspicious', 'matches_description',
         'call_related', 'wanted', 'other')),
    CONSTRAINT `ck_fpd_stops_search` CHECK (`search` IN
        ('none', 'consent', 'frisk', 'vehicle', 'person_and_vehicle')),
    CONSTRAINT `ck_fpd_stops_result` CHECK (`result` IN
        ('no_action', 'warning', 'citation', 'arrest', 'other')),
    CONSTRAINT `ck_fpd_stops_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;
