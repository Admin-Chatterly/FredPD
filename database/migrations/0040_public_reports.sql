-- 0040_public_reports.sql
--
-- Reports from the public (spec 7.29, civilian mode).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
-- What a member of the public hands in at a police front desk (a
-- `public_counter` placement): a stolen-property report, or a complaint about
-- the police. It is not an anmälan. An officer reads it, and either writes an
-- anmälan from it (`anmalan_id`), closes it as handled, or rejects it. A
-- complaint is read only by internal affairs.
--
-- Who handed it in is `reporter_identifier`, the character the server
-- resolved from the player at the desk. It is never taken from what the
-- player sent (invariant 1). `reporter_person_id` is that character's person
-- record, when the register has one.
--
-- Number: counter kind `public_report`, `{AGENCY}-M{YY}-{######}`
-- (Appendix D). The text is plain text, never markup (invariant 10).

CREATE TABLE IF NOT EXISTS `fpd_public_reports` (
    `id`                  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`           VARCHAR(32)     NOT NULL,
    `number`              VARCHAR(32)     NOT NULL,
    `kind`                VARCHAR(16)     NOT NULL,
    `reporter_identifier` VARCHAR(64)     NOT NULL,
    `reporter_person_id`  BIGINT UNSIGNED NULL,
    `reporter_name`       VARCHAR(128)    NOT NULL COMMENT 'As the character is named, at the desk',
    `occurred_at`         DATETIME(3)     NULL,
    `place`               VARCHAR(191)    NULL,
    `description`         VARCHAR(2000)   NOT NULL,
    `property`            VARCHAR(500)    NULL COMMENT 'What was taken, and any serial numbers',
    `status`              VARCHAR(16)     NOT NULL DEFAULT 'received',
    `handled_by`          VARCHAR(32)     NULL,
    `handled_at`          DATETIME(3)     NULL,
    `handled_note`        VARCHAR(500)    NULL,
    `anmalan_id`          BIGINT UNSIGNED NULL,
    `version`             INT UNSIGNED    NOT NULL DEFAULT 1,
    `created_at`          DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_public_reports_number` (`agency_id`, `number`),
    KEY `idx_fpd_public_reports_inbox` (`agency_id`, `kind`, `status`, `created_at`),
    KEY `idx_fpd_public_reports_reporter` (`agency_id`, `reporter_identifier`, `created_at`),
    CONSTRAINT `fk_fpd_public_reports_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_public_reports_person` FOREIGN KEY (`reporter_person_id`)
        REFERENCES `fpd_persons` (`id`) ON DELETE SET NULL,
    CONSTRAINT `fk_fpd_public_reports_anmalan` FOREIGN KEY (`anmalan_id`)
        REFERENCES `fpd_anmalan` (`id`) ON DELETE SET NULL,
    CONSTRAINT `ck_fpd_public_reports_kind` CHECK (`kind` IN ('stolen_property', 'complaint')),
    CONSTRAINT `ck_fpd_public_reports_status` CHECK (`status` IN ('received', 'handled', 'rejected')),
    CONSTRAINT `ck_fpd_public_reports_handled` CHECK (
        (`status` = 'received' AND `handled_by` IS NULL AND `handled_at` IS NULL)
        OR (`status` <> 'received' AND `handled_by` IS NOT NULL AND `handled_at` IS NOT NULL))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;
