-- 0027_personnel_issue_gate.sql
--
-- Gates issuing one equipment item or certification key behind a Discord
-- role or permission group, beyond the base
-- `personnel.equipment.manage`/`personnel.certification.manage` grant
-- (spec 7.22, 7.23; milestone M6).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
--
-- =============================================================================
-- WHY THIS IS THE IDENTICAL SHAPE `fpd_fleet`'s GATING COLUMNS USE (0003)
-- =============================================================================
--
-- 0003 already answered the exact question this migration asks, for the
-- motor pool: "everyone who holds the base permission" is too wide for a
-- department that wants only the air unit to draw the helicopter, and the
-- fix was two nullable columns -- `required_group`, `required_discord_role`
-- -- with the rule that satisfying either one opens the gate, and neither
-- set means open to anyone who already holds the base permission
-- (`garage/service.lua`'s `Garage.gatingSatisfied`).
--
-- Equipment items and certification keys are not rows in a table the way a
-- fleet entry is -- they are the closed lists `Personnel.isEquipmentItem`/
-- `isCertification` already check -- so the gate cannot live as two columns
-- on an existing row. It gets its own table instead, one row per
-- (agency, kind, item key) that a supervisor has chosen to gate, with the
-- identical two columns and the identical rule: a `swat` certification or a
-- `less_lethal` item with no gate row here stays exactly as issuable as it
-- was before this migration existed.
--
--
-- =============================================================================
-- WHY `required_group` OR `required_discord_role` IS REQUIRED, NOT BOTH NULLABLE
-- =============================================================================
--
-- `fpd_fleet.required_group`/`required_discord_role` are two columns on a row
-- that exists for many other reasons, so "both NULL" is the common,
-- unremarkable case -- most vehicles are not gated at all. A row in this
-- table exists for exactly one reason: to gate one key. A row with neither
-- column set would gate nothing while still occupying the unique slot for
-- that key, which reads as configured when it is not -- so the CHECK below
-- refuses it, and "not gated" is simply the absence of a row, the same as
-- it always was.

CREATE TABLE IF NOT EXISTS `fpd_personnel_issue_gate` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,

    `kind`        VARCHAR(16)     NOT NULL COMMENT 'equipment | certification',
    `item_key`    VARCHAR(64)     NOT NULL COMMENT 'One of the closed lists Personnel.isEquipmentItem/isCertification checks',

    `required_group`       VARCHAR(64) NULL,
    `required_discord_role` VARCHAR(32) NULL,

    `created_by`  VARCHAR(32)     NULL COMMENT 'Discord id',
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_personnel_issue_gate` (`agency_id`, `kind`, `item_key`),
    CONSTRAINT `fk_fpd_personnel_issue_gate_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_personnel_issue_gate_kind` CHECK (`kind` IN ('equipment', 'certification')),
    CONSTRAINT `ck_fpd_personnel_issue_gate_gate` CHECK (
        `required_group` IS NOT NULL OR `required_discord_role` IS NOT NULL)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;
