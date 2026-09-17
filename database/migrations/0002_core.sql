-- 0002_core.sql
--
-- The M1 platform core: agencies, the roster, the Discord-derived permission
-- model, the audit log, and the world placements that decide where each module
-- opens (spec 3.10, 4.3, 13).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
-- Every table is prefixed `fpd_` so it is obvious what belongs to FredPD inside
-- the ESX database it shares.

-- -----------------------------------------------------------------------------
-- Agencies and settings
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_agencies` (
    `id`          VARCHAR(32)  NOT NULL COMMENT 'Stable key, e.g. lspd',
    `name`        VARCHAR(191) NOT NULL,
    `short_name`  VARCHAR(32)  NOT NULL,
    `accent_color` CHAR(7)     NOT NULL DEFAULT '#1b4f9c',
    `enabled`     TINYINT(1)   NOT NULL DEFAULT 1,
    `created_at`  DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_at`  DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Runtime configuration that an administrator changes in game rather than in a
-- file. Scoped per agency, with a NULL agency meaning "server-wide".
CREATE TABLE IF NOT EXISTS `fpd_settings` (
    `id`         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`  VARCHAR(32)     NULL,
    `key`        VARCHAR(191)    NOT NULL,
    `value`      JSON            NOT NULL,
    `updated_at` DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    `updated_by` VARCHAR(191)    NULL COMMENT 'Discord id of the last editor',

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_settings` (`agency_id`, `key`),
    CONSTRAINT `fk_fpd_settings_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Roster
--
-- One row per person who may open FredPD, keyed by Discord id because that is
-- what access depends on (invariant 2, ADR-004). `identifier` binds the ESX
-- character; a Discord user holds one bound character per agency (spec 4.1).
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_officers` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `discord_id`  VARCHAR(32)     NOT NULL,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `identifier`  VARCHAR(191)    NULL COMMENT 'ESX character identifier, e.g. char1:license:…',
    `callsign`    VARCHAR(32)     NULL,
    `name`        VARCHAR(191)    NULL COMMENT 'Display name, set by command staff',
    `active`      TINYINT(1)      NOT NULL DEFAULT 1,
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_officers_discord_agency` (`discord_id`, `agency_id`),
    KEY `idx_fpd_officers_identifier` (`identifier`),
    CONSTRAINT `fk_fpd_officers_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Permissions (spec 4.3)
--
-- Discord role -> permission groups -> permission keys. The role map is a table
-- rather than a config file precisely so it can be edited from the MDT in game
-- (spec 7.30) without a restart.
-- -----------------------------------------------------------------------------

-- The gateway's bot writes this; FXServer only reads it (spec 4.2).
CREATE TABLE IF NOT EXISTS `fpd_discord_members` (
    `discord_id` VARCHAR(32) NOT NULL,
    `roles`      JSON        NOT NULL COMMENT 'Array of Discord role ids',
    `synced_at`  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`discord_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `fpd_permission_groups` (
    `key`         VARCHAR(64)  NOT NULL,
    `name`        VARCHAR(191) NOT NULL,
    `inherits`    VARCHAR(64)  NULL COMMENT 'Another group key, for bundles that extend one another',
    `description` VARCHAR(255) NULL,
    `created_at`  DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`key`),
    CONSTRAINT `fk_fpd_groups_inherits` FOREIGN KEY (`inherits`)
        REFERENCES `fpd_permission_groups` (`key`) ON DELETE SET NULL
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `fpd_group_permissions` (
    `group_key`  VARCHAR(64)  NOT NULL,
    `permission` VARCHAR(128) NOT NULL COMMENT 'A key from Appendix B',

    PRIMARY KEY (`group_key`, `permission`),
    CONSTRAINT `fk_fpd_group_permissions_group` FOREIGN KEY (`group_key`)
        REFERENCES `fpd_permission_groups` (`key`) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- The editable mapping: which Discord role grants which group, in which agency.
CREATE TABLE IF NOT EXISTS `fpd_role_map` (
    `id`               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `discord_role_id`  VARCHAR(32)     NOT NULL,
    `discord_role_name` VARCHAR(191)   NULL COMMENT 'Cached for display; Discord remains the source of truth',
    `group_key`        VARCHAR(64)     NOT NULL,
    `agency_id`        VARCHAR(32)     NOT NULL,
    `created_at`       DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `created_by`       VARCHAR(191)    NULL,

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_role_map` (`discord_role_id`, `group_key`, `agency_id`),
    KEY `idx_fpd_role_map_agency` (`agency_id`),
    CONSTRAINT `fk_fpd_role_map_group` FOREIGN KEY (`group_key`)
        REFERENCES `fpd_permission_groups` (`key`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_role_map_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Audit log (invariant 11)
--
-- Append-only. Nothing in the application ever updates or deletes a row here,
-- and the retention job is explicitly forbidden from touching it (spec 13.3).
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_audit_log` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `occurred_at` DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `action`      VARCHAR(128)    NOT NULL COMMENT 'e.g. placement.created, chat.sent',
    `discord_id`  VARCHAR(32)     NULL COMMENT 'NULL for server-initiated actions',
    `agency_id`   VARCHAR(32)     NULL,
    `subject_type` VARCHAR(64)    NULL COMMENT 'What was acted on',
    `subject_id`  VARCHAR(64)     NULL,
    `outcome`     VARCHAR(16)     NOT NULL DEFAULT 'ok' COMMENT 'ok | denied | error',
    `detail`      JSON            NULL COMMENT 'Never a full record: what changed, not the contents',

    PRIMARY KEY (`id`),
    KEY `idx_fpd_audit_occurred` (`occurred_at`),
    KEY `idx_fpd_audit_actor` (`discord_id`, `occurred_at`),
    KEY `idx_fpd_audit_subject` (`subject_type`, `subject_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- World placements (spec 3.10, ADR-006)
--
-- Where each module opens. Created and moved in game; never in a config file.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_placements` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `kind`        VARCHAR(48)     NOT NULL COMMENT 'What it opens: station_terminal, lab_terminal, motorpool, …',
    `agency_id`   VARCHAR(32)     NULL COMMENT 'NULL means shared between agencies',
    `interaction` VARCHAR(16)     NOT NULL DEFAULT 'zone' COMMENT 'prop | ped | zone',
    `model`       VARCHAR(64)     NULL COMMENT 'Prop or ped model for the prop and ped interactions',
    `x`           DOUBLE          NOT NULL,
    `y`           DOUBLE          NOT NULL,
    `z`           DOUBLE          NOT NULL,
    `heading`     FLOAT           NOT NULL DEFAULT 0,
    `radius`      FLOAT           NOT NULL DEFAULT 1.5,
    `label_key`   VARCHAR(128)    NULL COMMENT 'Locale key for the prompt -- never a literal string (invariant 6)',
    `enabled`     TINYINT(1)      NOT NULL DEFAULT 1,
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `created_by`  VARCHAR(191)    NULL,
    `updated_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    KEY `idx_fpd_placements_kind` (`kind`, `enabled`),
    CONSTRAINT `fk_fpd_placements_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Internal police chat (spec 7.26, ADR-007)
--
-- Append-only, so the channel is reviewable after an incident rather than
-- ephemeral. The recipient list is computed per message on the server and is
-- deliberately not stored: who could read it is derived from permissions at the
-- time, and storing a snapshot would invite treating it as authoritative.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_chat_messages` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `sent_at`     DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `agency_id`   VARCHAR(32)     NOT NULL,
    `discord_id`  VARCHAR(32)     NOT NULL COMMENT 'Author, from the session -- never from the client',
    `callsign`    VARCHAR(32)     NULL COMMENT 'Resolved server-side at send time',
    `author_name` VARCHAR(191)    NULL,
    `body`        VARCHAR(512)    NOT NULL,

    PRIMARY KEY (`id`),
    KEY `idx_fpd_chat_agency_time` (`agency_id`, `sent_at`),
    CONSTRAINT `fk_fpd_chat_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Motor pool (spec 7.31)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_fleet` (
    `id`            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`     VARCHAR(32)     NOT NULL,
    `model`         VARCHAR(64)     NOT NULL COMMENT 'Spawn name',
    `label_key`     VARCHAR(128)    NOT NULL COMMENT 'Locale key, not a literal name',
    `permission`    VARCHAR(128)    NULL COMMENT 'Extra permission beyond garage.vehicle.draw',
    `certification` VARCHAR(64)     NULL COMMENT 'Required certification, e.g. pursuit, air',
    `livery`        INT             NULL,
    `sort_order`    INT             NOT NULL DEFAULT 0,
    `enabled`       TINYINT(1)      NOT NULL DEFAULT 1,

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_fleet_agency_model` (`agency_id`, `model`),
    CONSTRAINT `fk_fpd_fleet_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `fpd_motorpool_log` (
    `id`           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `occurred_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `action`       VARCHAR(16)     NOT NULL COMMENT 'draw | return',
    `agency_id`    VARCHAR(32)     NOT NULL,
    `discord_id`   VARCHAR(32)     NOT NULL,
    `model`        VARCHAR(64)     NOT NULL,
    `plate`        VARCHAR(16)     NULL,
    -- Deliberately no foreign key: the log outlives the placement. A motor
    -- pool that is moved or removed must not erase the record of what was
    -- drawn from it.
    `placement_id` BIGINT UNSIGNED NULL,

    PRIMARY KEY (`id`),
    KEY `idx_fpd_motorpool_officer` (`discord_id`, `occurred_at`),
    KEY `idx_fpd_motorpool_plate` (`plate`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;
