-- FredPD — alla migrationer och seeds i en fil, sammanfogade 2026-09-24.
-- Genererad av tools/combine-sql, INTE en egen migration -- redigera aldrig den här filen,
-- redigera källfilerna i database/migrations/ och database/seeds/ och slå ihop på nytt.
-- Körs mot samma schema som ESX. Säker att köra om (migrationerna har IF NOT EXISTS,
-- seeds är upsert/INSERT IGNORE).

-- ============================================================
-- 0001_fredpd.sql
-- ============================================================
-- 0001_fredpd.sql
--
-- The whole FredPD schema, in one file: migration bookkeeping, the M1 platform
-- core (agencies, roster, the Discord-derived permission model, the audit log,
-- world placements, the internal channel, the motor pool) and the intelligence
-- register ported from PD-Span (spec 10).
--
-- Invariant 8: migrations are append-only. **This file has now shipped.** Never
-- edit it -- not even a comment. Correct anything here with `0002_*.sql`.
--
-- It is one file rather than three because FredPD has never been applied to a
-- running server: the only place the earlier 0001/0002/0003 split was ever
-- executed was CI, against a throwaway database. Consolidating before first
-- release is a rewrite of something nobody has installed; doing the same after
-- release would be exactly what invariant 8 forbids (ADR-009).
--
-- Tables are created in foreign-key order -- `fpd_agencies` before anything
-- that references it, `fpd_permission_groups` before the grants and the role
-- map, `fpd_intel_cases` before the notes and links that hang on it -- so the
-- file applies top to bottom against an empty database.
--
-- Every statement is `CREATE TABLE IF NOT EXISTS`, so re-applying this file is
-- a no-op rather than an error. CI proves that on every push.
--
-- Every table is prefixed `fpd_` so it is obvious what belongs to FredPD inside
-- the ESX database it shares.


-- =============================================================================
-- Migration bookkeeping (spec 17.2)
--
-- `checksum` is what lets the runner refuse to start against an unexpected
-- schema (spec 16): if a shipped migration was edited after the fact, the
-- recorded checksum no longer matches the file and the server stops instead of
-- applying a half-known schema to production data.
-- =============================================================================

CREATE TABLE IF NOT EXISTS `fpd_migrations` (
    `id`          INT UNSIGNED NOT NULL AUTO_INCREMENT,
    `name`        VARCHAR(191) NOT NULL,
    `checksum`    CHAR(64)     NOT NULL COMMENT 'SHA-256 of the file as applied',
    `applied_at`  DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `duration_ms` INT UNSIGNED NOT NULL DEFAULT 0,

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_migrations_name` (`name`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;


-- =============================================================================
-- PLATFORM CORE
-- =============================================================================

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


-- =============================================================================
-- INTELLIGENCE REGISTER (spec 10)
--
-- PD-Span's data model, ported from Supabase/Postgres onto the server's own
-- MariaDB so everything persists in the game database rather than in a separate
-- hosted service.
--
-- What changed in the port, and why:
--
--   * `uuid` primary keys become `BIGINT UNSIGNED AUTO_INCREMENT` (spec 13.1).
--   * `text[]` tags become a join table. MariaDB has no array type, and a real
--     table makes the tag filter a GROUP BY instead of an unnest.
--   * `unique nulls not distinct` has no MariaDB equivalent: MySQL and MariaDB
--     treat NULLs as distinct, so the constraint would not have held. Replaced
--     with generated `target_kind`/`target_id` columns, which are never NULL.
--   * Row Level Security becomes server-side checks in the service layer
--     (invariant 4). PD-Span's policies granted every authenticated user
--     everything; FredPD's permissions are Discord-derived and per-route.
--   * `agency_id` is new. PD-Span had one department; FredPD is multi-agency.
--   * `classification` is new (spec 4.5). PD-Span had no concept of it, which
--     is the single largest gap the inventory found.
--   * Write-time normalisation (upper-case plates, blank-to-NULL, tag casing)
--     moves from Postgres triggers into `service.lua`, where busted can test it.
--   * Generated fallback labels ("Okänd", "Inget regnr") are NOT ported. They
--     were Swedish strings baked into the database; a label belongs in the
--     locale files (invariant 6), so these columns stay NULL and the interface
--     renders the key.
--
-- The existing PD-Span data is deliberately NOT migrated: this starts empty and
-- the register is built up in game. Nothing here carries the old identifiers.
-- If that decision is ever revisited, a later migration adds a nullable unique
-- `span_uuid` per table and the import keys on it -- it is an ALTER, not a
-- redesign.
--
-- Deliberately lost: pg_trgm typo tolerance. Search is substring-based, as
-- PD-Span's primary path already was. Fuzzy ranking can come back later.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Persons of interest
--
-- Every field but the id is optional: a row can be nothing but a physical
-- description. That is deliberate and is how a tip enters the register before
-- anyone knows who it is about.
--
-- This is NOT the master name index (spec 7.3). `master_person_id` is where an
-- intelligence subject is later tied to a confirmed person record, once M2
-- builds one. Keeping them apart is what stops an unverified description from
-- becoming an identity by accident.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_intel_persons` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `master_person_id` BIGINT UNSIGNED NULL COMMENT 'Master name index record, once M2 exists',

    `name`        VARCHAR(191)    NULL,
    `alias`       VARCHAR(191)    NULL,
    `description` TEXT            NULL,
    `status`      VARCHAR(32)     NOT NULL DEFAULT 'unknown',
    `photo_path`  VARCHAR(512)    NULL COMMENT 'Media reference, served through the gateway',

    `classification` VARCHAR(16)  NOT NULL DEFAULT 'internal',
    `version`     INT UNSIGNED    NOT NULL DEFAULT 1,
    `created_by`  VARCHAR(32)     NULL COMMENT 'Discord id',
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    `search_text` TEXT AS (LOWER(CONCAT_WS(' ', `name`, `alias`, `description`))) STORED,

    PRIMARY KEY (`id`),
    KEY `idx_fpd_intel_persons_agency` (`agency_id`, `updated_at`),
    KEY `idx_fpd_intel_persons_status` (`agency_id`, `status`),
    KEY `idx_fpd_intel_persons_master` (`master_person_id`),
    CONSTRAINT `fk_fpd_intel_persons_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_intel_persons_status` CHECK (`status` IN
        ('unknown', 'poi', 'active_investigation', 'warrant', 'cleared', 'incarcerated', 'deceased')),
    CONSTRAINT `ck_fpd_intel_persons_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Organisations: gangs, crews, cartels, businesses
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_intel_orgs` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,

    `name`        VARCHAR(191)    NOT NULL,
    `type`        VARCHAR(32)     NULL,
    `territory`   VARCHAR(191)    NULL,
    `status`      VARCHAR(32)     NOT NULL DEFAULT 'active',
    `notes`       TEXT            NULL,

    `classification` VARCHAR(16)  NOT NULL DEFAULT 'internal',
    `version`     INT UNSIGNED    NOT NULL DEFAULT 1,
    `created_by`  VARCHAR(32)     NULL,
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    `search_text` TEXT AS (LOWER(CONCAT_WS(' ', `name`, `territory`, `notes`))) STORED,

    PRIMARY KEY (`id`),
    KEY `idx_fpd_intel_orgs_agency` (`agency_id`, `updated_at`),
    CONSTRAINT `fk_fpd_intel_orgs_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_intel_orgs_type` CHECK (`type` IS NULL OR `type` IN
        ('gang', 'cartel', 'business', 'crew', 'other')),
    CONSTRAINT `ck_fpd_intel_orgs_status` CHECK (`status` IN ('active', 'disbanded', 'dormant')),
    CONSTRAINT `ck_fpd_intel_orgs_name` CHECK (CHAR_LENGTH(TRIM(`name`)) > 0),
    CONSTRAINT `ck_fpd_intel_orgs_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Person <-> organisation
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_intel_memberships` (
    `person_id`    BIGINT UNSIGNED NOT NULL,
    `org_id`       BIGINT UNSIGNED NOT NULL,
    `role`         VARCHAR(191)    NULL,
    `is_confirmed` TINYINT(1)      NOT NULL DEFAULT 0 COMMENT 'Confirmed, as opposed to suspected',
    `created_by`   VARCHAR(32)     NULL,
    `created_at`   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`person_id`, `org_id`),
    KEY `idx_fpd_intel_memberships_org` (`org_id`),
    CONSTRAINT `fk_fpd_intel_memberships_person` FOREIGN KEY (`person_id`)
        REFERENCES `fpd_intel_persons` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_intel_memberships_org` FOREIGN KEY (`org_id`)
        REFERENCES `fpd_intel_orgs` (`id`) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Person <-> person
--
-- Undirected: one row per pair, kept in a fixed order by the CHECK so the same
-- association can never be stored twice facing opposite ways. Worth keeping --
-- it is the neatest thing in the original schema.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_intel_associates` (
    `person_id`    BIGINT UNSIGNED NOT NULL,
    `associate_id` BIGINT UNSIGNED NOT NULL,
    `relationship` VARCHAR(191)    NULL,
    `is_confirmed` TINYINT(1)      NOT NULL DEFAULT 0,
    `created_by`   VARCHAR(32)     NULL,
    `created_at`   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`person_id`, `associate_id`),
    KEY `idx_fpd_intel_associates_other` (`associate_id`),
    CONSTRAINT `fk_fpd_intel_associates_person` FOREIGN KEY (`person_id`)
        REFERENCES `fpd_intel_persons` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_intel_associates_associate` FOREIGN KEY (`associate_id`)
        REFERENCES `fpd_intel_persons` (`id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_intel_associates_ordered` CHECK (`person_id` < `associate_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Cases and what is linked to them
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_intel_cases` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,

    `title`       VARCHAR(191)    NOT NULL,
    `description` TEXT            NULL,
    `status`      VARCHAR(16)     NOT NULL DEFAULT 'open',

    `classification` VARCHAR(16)  NOT NULL DEFAULT 'internal',
    `version`     INT UNSIGNED    NOT NULL DEFAULT 1,
    `created_by`  VARCHAR(32)     NULL,
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    KEY `idx_fpd_intel_cases_agency` (`agency_id`, `status`, `updated_at`),
    CONSTRAINT `fk_fpd_intel_cases_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_intel_cases_status` CHECK (`status` IN ('open', 'closed', 'cold')),
    CONSTRAINT `ck_fpd_intel_cases_title` CHECK (CHAR_LENGTH(TRIM(`title`)) > 0),
    CONSTRAINT `ck_fpd_intel_cases_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- The intelligence log
--
-- A note attaches to a person, an organisation, a case, any combination, or
-- nothing at all -- which is how a tip is recorded before anyone knows who it
-- concerns.
--
-- Deleting an organisation DETACHES its notes rather than deleting them
-- (PD-Span migration 0003). Intelligence outliving the record it hung on is
-- correct behaviour and is preserved here deliberately.
--
-- `source` and `confidence` are PD-Span's own vocabulary, kept verbatim.
-- FredPD's graded scheme (A-F reliability, 1-6 credibility, spec 10.6) is
-- carried alongside and left NULL: there is no honest automatic mapping between
-- the two, so imported intelligence stays ungraded until an analyst grades it.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_intel_notes` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,

    `person_id`   BIGINT UNSIGNED NULL,
    `org_id`      BIGINT UNSIGNED NULL,
    `case_id`     BIGINT UNSIGNED NULL,

    `body`        TEXT            NOT NULL,
    `source`      VARCHAR(32)     NULL,
    `confidence`  VARCHAR(16)     NOT NULL DEFAULT 'medium',

    `source_reliability` CHAR(1)  NULL COMMENT 'A-F (spec 10.6); NULL means not evaluated',
    `info_credibility`   TINYINT  NULL COMMENT '1-6 (spec 10.6); NULL means not evaluated',

    `classification` VARCHAR(16)  NOT NULL DEFAULT 'internal',
    `version`     INT UNSIGNED    NOT NULL DEFAULT 1,
    `created_by`  VARCHAR(32)     NULL,
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    KEY `idx_fpd_intel_notes_agency_time` (`agency_id`, `created_at`),
    KEY `idx_fpd_intel_notes_person` (`person_id`, `created_at`),
    KEY `idx_fpd_intel_notes_org` (`org_id`, `created_at`),
    KEY `idx_fpd_intel_notes_case` (`case_id`, `created_at`),
    CONSTRAINT `fk_fpd_intel_notes_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_intel_notes_person` FOREIGN KEY (`person_id`)
        REFERENCES `fpd_intel_persons` (`id`) ON DELETE CASCADE,
    -- Detach, never delete: the intelligence outlives the organisation.
    CONSTRAINT `fk_fpd_intel_notes_org` FOREIGN KEY (`org_id`)
        REFERENCES `fpd_intel_orgs` (`id`) ON DELETE SET NULL,
    CONSTRAINT `fk_fpd_intel_notes_case` FOREIGN KEY (`case_id`)
        REFERENCES `fpd_intel_cases` (`id`) ON DELETE SET NULL,
    CONSTRAINT `ck_fpd_intel_notes_body` CHECK (CHAR_LENGTH(TRIM(`body`)) > 0),
    CONSTRAINT `ck_fpd_intel_notes_source` CHECK (`source` IS NULL OR `source` IN
        ('informant', 'wiretap', 'patrol', 'tip', 'surveillance', 'other')),
    CONSTRAINT `ck_fpd_intel_notes_confidence` CHECK (`confidence` IN ('low', 'medium', 'high')),
    CONSTRAINT `ck_fpd_intel_notes_reliability` CHECK (`source_reliability` IS NULL
        OR `source_reliability` IN ('A', 'B', 'C', 'D', 'E', 'F')),
    CONSTRAINT `ck_fpd_intel_notes_credibility` CHECK (`info_credibility` IS NULL
        OR (`info_credibility` BETWEEN 1 AND 6)),
    CONSTRAINT `ck_fpd_intel_notes_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Tags, as rows rather than an array. Normalised to lower case by the service.
CREATE TABLE IF NOT EXISTS `fpd_intel_note_tags` (
    `note_id` BIGINT UNSIGNED NOT NULL,
    `tag`     VARCHAR(64)     NOT NULL,

    PRIMARY KEY (`note_id`, `tag`),
    KEY `idx_fpd_intel_note_tags_tag` (`tag`),
    CONSTRAINT `fk_fpd_intel_note_tags_note` FOREIGN KEY (`note_id`)
        REFERENCES `fpd_intel_notes` (`id`) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Vehicles seen in intelligence
--
-- Not the vehicle registry (spec 7.4) -- that is authoritative and comes in M2.
-- This is "a car that keeps turning up", which may have no owner on record.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_intel_vehicles` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `person_id`   BIGINT UNSIGNED NULL,

    `plate`       VARCHAR(16)     NULL COMMENT 'Stored upper-case by the service',
    `model`       VARCHAR(64)     NULL,
    `color`       VARCHAR(64)     NULL,
    `notes`       TEXT            NULL,

    `classification` VARCHAR(16)  NOT NULL DEFAULT 'internal',
    `version`     INT UNSIGNED    NOT NULL DEFAULT 1,
    `created_by`  VARCHAR(32)     NULL,
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    `search_text` TEXT AS (LOWER(CONCAT_WS(' ', `plate`, `model`, `color`, `notes`))) STORED,

    PRIMARY KEY (`id`),
    KEY `idx_fpd_intel_vehicles_plate` (`plate`),
    KEY `idx_fpd_intel_vehicles_person` (`person_id`),
    KEY `idx_fpd_intel_vehicles_agency` (`agency_id`, `updated_at`),
    CONSTRAINT `fk_fpd_intel_vehicles_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    -- The car outlives the person record it was linked to.
    CONSTRAINT `fk_fpd_intel_vehicles_person` FOREIGN KEY (`person_id`)
        REFERENCES `fpd_intel_persons` (`id`) ON DELETE SET NULL,
    CONSTRAINT `ck_fpd_intel_vehicles_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Case links: a link points at exactly one of a person or an organisation.
--
-- PD-Span enforced uniqueness with `unique nulls not distinct`, which MariaDB
-- does not have -- NULLs count as distinct here, so that constraint would have
-- allowed duplicates. The generated columns below are never NULL, so the unique
-- key actually holds.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_intel_case_links` (
    `id`         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `case_id`    BIGINT UNSIGNED NOT NULL,
    `person_id`  BIGINT UNSIGNED NULL,
    `org_id`     BIGINT UNSIGNED NULL,
    `role`       VARCHAR(191)    NULL COMMENT 'Role in this case specifically',
    `created_by` VARCHAR(32)     NULL,
    `created_at` DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    `target_kind` VARCHAR(8) AS (IF(`person_id` IS NOT NULL, 'person', 'org')) STORED,
    `target_id`   BIGINT UNSIGNED AS (COALESCE(`person_id`, `org_id`)) STORED,

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_intel_case_links` (`case_id`, `target_kind`, `target_id`),
    KEY `idx_fpd_intel_case_links_person` (`person_id`),
    KEY `idx_fpd_intel_case_links_org` (`org_id`),
    CONSTRAINT `fk_fpd_intel_case_links_case` FOREIGN KEY (`case_id`)
        REFERENCES `fpd_intel_cases` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_intel_case_links_person` FOREIGN KEY (`person_id`)
        REFERENCES `fpd_intel_persons` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_intel_case_links_org` FOREIGN KEY (`org_id`)
        REFERENCES `fpd_intel_orgs` (`id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_intel_case_links_one_target`
        CHECK ((`person_id` IS NOT NULL) + (`org_id` IS NOT NULL) = 1)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Evidence attached to intelligence
--
-- Either an uploaded file or an external link (a Medal clip, YouTube,
-- Streamable, a direct image address), never both.
--
-- This is intelligence *attachment*, not chain-of-custody evidence. Seized
-- property and forensics are section 8 and are a different thing entirely.
--
-- Uploads need the gateway's media service to serve them through signed URLs
-- (invariant 9), which is not built yet. External links work today; the column
-- is here so the data model does not need changing when it is.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_intel_evidence` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,

    `person_id`   BIGINT UNSIGNED NULL,
    `org_id`      BIGINT UNSIGNED NULL,
    `case_id`     BIGINT UNSIGNED NULL,

    `storage_path` VARCHAR(512)   NULL COMMENT 'Media reference, served through the gateway',
    `url`          VARCHAR(1024)  NULL COMMENT 'External link',
    `caption`      VARCHAR(512)   NULL,

    `classification` VARCHAR(16)  NOT NULL DEFAULT 'internal',
    `created_by`  VARCHAR(32)     NULL,
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    KEY `idx_fpd_intel_evidence_person` (`person_id`, `created_at`),
    KEY `idx_fpd_intel_evidence_org` (`org_id`, `created_at`),
    KEY `idx_fpd_intel_evidence_case` (`case_id`, `created_at`),
    CONSTRAINT `fk_fpd_intel_evidence_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_intel_evidence_person` FOREIGN KEY (`person_id`)
        REFERENCES `fpd_intel_persons` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_intel_evidence_org` FOREIGN KEY (`org_id`)
        REFERENCES `fpd_intel_orgs` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_intel_evidence_case` FOREIGN KEY (`case_id`)
        REFERENCES `fpd_intel_cases` (`id`) ON DELETE CASCADE,
    -- An evidence row must always hang on something.
    CONSTRAINT `ck_fpd_intel_evidence_target` CHECK (
        (`person_id` IS NOT NULL) + (`org_id` IS NOT NULL) + (`case_id` IS NOT NULL) >= 1),
    CONSTRAINT `ck_fpd_intel_evidence_file_or_url` CHECK (
        (`storage_path` IS NOT NULL) + (`url` IS NOT NULL) = 1),
    CONSTRAINT `ck_fpd_intel_evidence_url_http` CHECK (
        `url` IS NULL OR `url` LIKE 'http://%' OR `url` LIKE 'https://%'),
    CONSTRAINT `ck_fpd_intel_evidence_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- ============================================================
-- 0002_evidence.sql
-- ============================================================
-- 0002_evidence.sql
--
-- Evidence, chain of custody, scenes, the forensic lab and the forensic
-- indexes (spec 8, milestone M3).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
-- The whole of section 8 rests on one idea, 8.1: **hidden truth**. A character's
-- DNA and fingerprint, and a weapon's barrel signature, exist only in this
-- database. No client ever receives them -- not a criminal's, and not an
-- officer's. What an evidence item carries is an opaque reference, and what the
-- lab returns is a *result*, computed on the server from truth the client never
-- saw.
--
-- That is why the owner columns below are deliberately not on the same table as
-- anything a client reads. A SELECT written for a client payload has to name its
-- columns, and the ones that would leak are in `fpd_evidence_owner`, which no
-- client-facing read ever joins. Putting them in `fpd_evidence` would make the
-- leak a `SELECT *` away.
--
-- Nothing here is reused from the reference script (spec 8, preamble): its
-- mechanics are the gameplay model, its code is not.

-- =============================================================================
-- HIDDEN TRUTH (8.1)
-- =============================================================================

-- One row per character. Written once, when the character is first seen; the
-- values never change, because a person's DNA does not.
--
-- `identifier` is the ESX character identifier rather than a Discord id: DNA
-- belongs to the character, and one Discord account holds several.
CREATE TABLE IF NOT EXISTS `fpd_biometrics` (
    `identifier`  VARCHAR(191) NOT NULL,
    `dna_profile` CHAR(64)     NOT NULL COMMENT 'Opaque. Compared, never displayed.',
    `fingerprint` CHAR(64)     NOT NULL COMMENT 'Opaque. Compared, never displayed.',
    `created_at`  DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`identifier`),
    UNIQUE KEY `uq_fpd_biometrics_dna` (`dna_profile`),
    UNIQUE KEY `uq_fpd_biometrics_print` (`fingerprint`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- One row per weapon serial. The barrel signature is what links a casing or a
-- bullet to the gun that fired it; the tool-mark signature does the same for
-- crowbars and lockpicks.
CREATE TABLE IF NOT EXISTS `fpd_weapon_signatures` (
    `serial`             VARCHAR(64) NOT NULL,
    `barrel_signature`   CHAR(64)    NOT NULL,
    `toolmark_signature` CHAR(64)    NOT NULL,
    -- Filing the serial off does not change the barrel. That is the entire
    -- point of ballistics, and of 8.9's restoration mechanic.
    `serial_obliterated` TINYINT(1)  NOT NULL DEFAULT 0,
    `created_at`         DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`serial`),
    KEY `idx_fpd_weapon_barrel` (`barrel_signature`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- =============================================================================
-- SCENES (8.4)
-- =============================================================================

CREATE TABLE IF NOT EXISTS `fpd_scenes` (
    `id`            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `scene_number`  VARCHAR(32)     NOT NULL COMMENT 'Generated server-side (invariant 1)',
    `agency_id`     VARCHAR(32)     NOT NULL,
    `case_number`   VARCHAR(32)     NULL COMMENT 'Free text until M2 owns cases',

    `x`             DOUBLE          NOT NULL,
    `y`             DOUBLE          NOT NULL,
    `z`             DOUBLE          NOT NULL,
    `radius`        FLOAT           NOT NULL DEFAULT 25.0,

    `status`        VARCHAR(16)     NOT NULL DEFAULT 'open',
    `created_by`    VARCHAR(32)     NULL COMMENT 'Discord id',
    `created_at`    DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `released_by`   VARCHAR(32)     NULL,
    `released_at`   DATETIME(3)     NULL,

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_scenes_number` (`scene_number`),
    KEY `idx_fpd_scenes_agency` (`agency_id`, `status`, `created_at`),
    CONSTRAINT `fk_fpd_scenes_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_scenes_status` CHECK (`status` IN ('open', 'released')),
    CONSTRAINT `ck_fpd_scenes_radius` CHECK (`radius` > 0 AND `radius` <= 500)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Who was inside the perimeter, and when. Contamination is a defence argument,
-- so this is evidence about the evidence and is never edited or deleted.
--
-- Deliberately keyed on the character identifier as well as the Discord id: the
-- entry log is about a body in a space, and "which of their characters" is the
-- question a defence lawyer asks.
CREATE TABLE IF NOT EXISTS `fpd_scene_entries` (
    `id`         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `scene_id`   BIGINT UNSIGNED NOT NULL,
    `discord_id` VARCHAR(32)     NULL COMMENT 'NULL for a player with no FredPD session -- a civilian walking through',
    `identifier` VARCHAR(191)    NOT NULL,
    `entered_at` DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `left_at`    DATETIME(3)     NULL,
    `protected`  TINYINT(1)      NOT NULL DEFAULT 0 COMMENT 'Wearing protective equipment on entry',

    PRIMARY KEY (`id`),
    KEY `idx_fpd_scene_entries_scene` (`scene_id`, `entered_at`),
    CONSTRAINT `fk_fpd_scene_entries_scene` FOREIGN KEY (`scene_id`)
        REFERENCES `fpd_scenes` (`id`) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- =============================================================================
-- EVIDENCE (8.2, 8.5)
-- =============================================================================

-- What an officer, and the NUI, may see. Every column here is safe to send to a
-- session that holds `evidence.item.view`.
CREATE TABLE IF NOT EXISTS `fpd_evidence` (
    `id`              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    -- The opaque handle an inventory item carries (8.1.2). Random, not derived:
    -- anything derived from the owner would be the leak this design exists to
    -- prevent, however well hashed.
    `ref`             CHAR(32)        NOT NULL,
    `evidence_number` VARCHAR(32)     NOT NULL COMMENT 'Generated server-side',
    `agency_id`       VARCHAR(32)     NOT NULL,
    `scene_id`        BIGINT UNSIGNED NULL,
    `case_number`     VARCHAR(32)     NULL,

    `type`            VARCHAR(32)     NOT NULL COMMENT '8.2: print, blood, dna_touch, casing, …',
    `packaging`       VARCHAR(32)     NULL COMMENT '8.5: envelope, swab_box, lift_card, …',
    `seal_state`      VARCHAR(16)     NOT NULL DEFAULT 'sealed',
    `marker_number`   INT UNSIGNED    NULL COMMENT 'The numbered marker it was photographed under',
    `description`     VARCHAR(512)    NULL,

    -- 0-100. Set at collection from age, weather and contamination (8.1.4) and
    -- reduced by cleaning. The lab reads this, not the client.
    `quality`         TINYINT UNSIGNED NOT NULL DEFAULT 100,

    `collected_by`    VARCHAR(32)     NULL COMMENT 'Discord id',
    `collected_at`    DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `storage_location` VARCHAR(64)    NULL COMMENT 'Assigned at property room intake (8.6)',
    `status`          VARCHAR(16)     NOT NULL DEFAULT 'collected',

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_evidence_ref` (`ref`),
    UNIQUE KEY `uq_fpd_evidence_number` (`evidence_number`),
    KEY `idx_fpd_evidence_scene` (`scene_id`),
    KEY `idx_fpd_evidence_case` (`case_number`),
    KEY `idx_fpd_evidence_agency` (`agency_id`, `status`, `collected_at`),
    CONSTRAINT `fk_fpd_evidence_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    -- Evidence outlives the scene record it was found at.
    CONSTRAINT `fk_fpd_evidence_scene` FOREIGN KEY (`scene_id`)
        REFERENCES `fpd_scenes` (`id`) ON DELETE SET NULL,
    CONSTRAINT `ck_fpd_evidence_seal` CHECK (`seal_state` IN ('sealed', 'broken', 'resealed')),
    CONSTRAINT `ck_fpd_evidence_status` CHECK (`status` IN
        ('collected', 'in_locker', 'in_property', 'checked_out', 'at_lab', 'released', 'destroyed')),
    CONSTRAINT `ck_fpd_evidence_quality` CHECK (`quality` <= 100)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- The half no client ever sees (8.11).
--
-- A separate table rather than more columns on `fpd_evidence`, so that leaking
-- it takes a deliberate JOIN that a reviewer will notice, instead of a careless
-- `SELECT *`. One row per evidence item, dropped with it.
CREATE TABLE IF NOT EXISTS `fpd_evidence_owner` (
    `evidence_id`   BIGINT UNSIGNED NOT NULL,
    -- Whose biometric this is. NULL for evidence that carries no person, such
    -- as a casing, which carries a weapon instead.
    `identifier`    VARCHAR(191)    NULL,
    `weapon_serial` VARCHAR(64)     NULL,

    PRIMARY KEY (`evidence_id`),
    KEY `idx_fpd_evidence_owner_identifier` (`identifier`),
    KEY `idx_fpd_evidence_owner_serial` (`weapon_serial`),
    CONSTRAINT `fk_fpd_evidence_owner_evidence` FOREIGN KEY (`evidence_id`)
        REFERENCES `fpd_evidence` (`id`) ON DELETE CASCADE,
    -- A trace with neither a person nor a weapon behind it is a bug in the
    -- generation pipeline, not a thing that exists.
    CONSTRAINT `ck_fpd_evidence_owner_one` CHECK (
        (`identifier` IS NOT NULL) + (`weapon_serial` IS NOT NULL) >= 1)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- =============================================================================
-- CHAIN OF CUSTODY (8.6)
-- =============================================================================

-- Append-only, like the audit log and for the same reason: a custody record
-- that can be edited is worth nothing in court. Nothing in the application
-- updates or deletes a row here.
CREATE TABLE IF NOT EXISTS `fpd_custody_log` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `evidence_id` BIGINT UNSIGNED NOT NULL,
    `occurred_at` DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `action`      VARCHAR(24)     NOT NULL COMMENT 'collect | deposit | intake | transfer | checkout | checkin | release | destroy',
    `from_party`  VARCHAR(191)    NULL COMMENT 'Officer, locker or storage location',
    `to_party`    VARCHAR(191)    NULL,
    `reason`      VARCHAR(255)    NULL,
    -- The electronic signature (8.6): who attests to this transfer. From the
    -- session, never from input.
    `signed_by`   VARCHAR(32)     NOT NULL,

    PRIMARY KEY (`id`),
    KEY `idx_fpd_custody_evidence` (`evidence_id`, `occurred_at`),
    KEY `idx_fpd_custody_signer` (`signed_by`, `occurred_at`),
    CONSTRAINT `fk_fpd_custody_evidence` FOREIGN KEY (`evidence_id`)
        REFERENCES `fpd_evidence` (`id`) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- =============================================================================
-- FORENSIC LAB (8.7)
-- =============================================================================

CREATE TABLE IF NOT EXISTS `fpd_lab_requests` (
    `id`            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`     VARCHAR(32)     NOT NULL,
    `case_number`   VARCHAR(32)     NULL,
    `priority`      VARCHAR(16)     NOT NULL DEFAULT 'routine',
    `justification` VARCHAR(512)    NULL,
    `requested_by`  VARCHAR(32)     NOT NULL,
    `requested_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `status`        VARCHAR(16)     NOT NULL DEFAULT 'queued',

    PRIMARY KEY (`id`),
    KEY `idx_fpd_lab_requests_queue` (`agency_id`, `status`, `priority`, `requested_at`),
    CONSTRAINT `fk_fpd_lab_requests_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_lab_requests_priority` CHECK (`priority` IN ('routine', 'expedited', 'urgent')),
    CONSTRAINT `ck_fpd_lab_requests_status` CHECK (`status` IN ('queued', 'in_progress', 'complete', 'cancelled'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- One analysis of one item. `due_at` is stored rather than counted down in
-- memory, so a restart does not reset every timer in the lab (8.7).
CREATE TABLE IF NOT EXISTS `fpd_lab_analyses` (
    `id`            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `request_id`    BIGINT UNSIGNED NOT NULL,
    `evidence_id`   BIGINT UNSIGNED NOT NULL,
    `analysis`      VARCHAR(32)     NOT NULL COMMENT 'dna | print_comparison | print_search | ballistics | gsr | drug_id',

    `status`        VARCHAR(16)     NOT NULL DEFAULT 'queued',
    `assigned_to`   VARCHAR(32)     NULL,
    `started_at`    DATETIME(3)     NULL,
    `due_at`        DATETIME(3)     NULL COMMENT 'Persisted so timers survive a restart',
    `completed_at`  DATETIME(3)     NULL,

    -- The standard result language of 8.7. Free text would make a result
    -- unsearchable and let an analyst write a conclusion the evidence does not
    -- support.
    `result_code`   VARCHAR(32)     NULL,
    `observations`  VARCHAR(1024)   NULL COMMENT 'Method and notes. Not the conclusion.',
    `reviewed_by`   VARCHAR(32)     NULL,
    `released_at`   DATETIME(3)     NULL,

    PRIMARY KEY (`id`),
    KEY `idx_fpd_lab_analyses_request` (`request_id`),
    KEY `idx_fpd_lab_analyses_evidence` (`evidence_id`),
    KEY `idx_fpd_lab_analyses_due` (`status`, `due_at`),
    CONSTRAINT `fk_fpd_lab_analyses_request` FOREIGN KEY (`request_id`)
        REFERENCES `fpd_lab_requests` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_lab_analyses_evidence` FOREIGN KEY (`evidence_id`)
        REFERENCES `fpd_evidence` (`id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_lab_analyses_status` CHECK (`status` IN
        ('queued', 'in_progress', 'complete', 'reviewed', 'released', 'cancelled')),
    CONSTRAINT `ck_fpd_lab_analyses_result` CHECK (`result_code` IS NULL OR `result_code` IN
        ('profile_obtained', 'partial_profile', 'mixture', 'no_profile',
         'identification', 'exclusion', 'inconclusive', 'insufficient',
         'candidate_match', 'no_match'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- =============================================================================
-- FORENSIC INDEXES (8.8)
-- =============================================================================

-- The searchable indexes: offender and suspect references, unidentified traces,
-- ten-print cards, ballistics.
--
-- `profile` holds the same opaque value as the biometric or barrel signature it
-- came from, which is what makes a search an equality test rather than a join
-- across the hidden tables. A hit is a *lead* (8.1.3): confirmation needs a
-- fresh reference sample, which is why `fpd_lab_analyses` exists separately.
CREATE TABLE IF NOT EXISTS `fpd_forensic_index` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `index_kind`  VARCHAR(24)     NOT NULL,
    `profile`     CHAR(64)        NOT NULL,

    -- A reference entry names its subject. A trace entry does not -- that is
    -- the whole point of the trace index.
    `identifier`  VARCHAR(191)    NULL,
    `evidence_id` BIGINT UNSIGNED NULL,

    `agency_id`   VARCHAR(32)     NOT NULL,
    `added_by`    VARCHAR(32)     NULL,
    `added_at`    DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    -- Expungement (8.8): acquittal and time limits remove a profile. Kept as a
    -- timestamp rather than a delete, so that a removal is itself auditable.
    `removed_at`  DATETIME(3)     NULL,
    `removed_by`  VARCHAR(32)     NULL,

    PRIMARY KEY (`id`),
    KEY `idx_fpd_forensic_index_search` (`index_kind`, `profile`, `removed_at`),
    KEY `idx_fpd_forensic_index_subject` (`identifier`),
    CONSTRAINT `fk_fpd_forensic_index_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    -- CASCADE, not SET NULL. A trace entry exists because an item was found;
    -- without the item there is no provenance for the profile and it must not
    -- stay searchable. MariaDB also refuses the alternative outright (error
    -- 1901): a CHECK cannot constrain a column a foreign key sets to NULL,
    -- because the delete would then produce a row the CHECK forbids. Reference
    -- entries have no `evidence_id`, so nothing cascades onto them.
    CONSTRAINT `fk_fpd_forensic_index_evidence` FOREIGN KEY (`evidence_id`)
        REFERENCES `fpd_evidence` (`id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_forensic_index_kind` CHECK (`index_kind` IN
        ('dna_convicted', 'dna_suspect', 'dna_trace', 'fingerprint', 'fingerprint_latent', 'ballistics')),
    CONSTRAINT `ck_fpd_forensic_index_subject` CHECK (
        (`identifier` IS NOT NULL) + (`evidence_id` IS NOT NULL) >= 1)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- ============================================================
-- 0003_fleet_gating.sql
-- ============================================================
-- 0003_fleet_gating.sql
--
-- Fleet gating for the motor pool (spec 7.31): which officers may draw which
-- vehicle, configured from the fleet editor instead of by hand in SQL.
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
-- Until now `fpd_fleet` could restrict a vehicle two ways, both of them
-- permission keys: `permission` (an extra key beyond `garage.vehicle.draw`) and
-- `certification` (7.23, not yet issued to anyone). Neither answers the request
-- a department actually makes, which is "the air unit is the people with the Air
-- Support role in Discord" -- a role that already exists and is already
-- maintained, with no permission group behind it.
--
-- So two more nullable columns, and one rule over both:
--
--   A vehicle is drawable when EITHER the officer holds the Discord role in
--   `required_discord_role`, OR their effective permissions satisfy the
--   permission group in `required_group`, OR both columns are NULL.
--
-- Either gate opens the vehicle. Requiring both would mean every gated vehicle
-- needs two pieces of configuration kept in step, and the first one to drift
-- takes the vehicle away from everyone. The rule lives in one pure function --
-- `FredPD.Modules.garage.gatingSatisfied` -- so it is tested rather than
-- reimplemented per caller, and it is evaluated on the server at draw time
-- (invariant 4). These columns narrow access and never widen it: an officer
-- still needs `garage.vehicle.draw`, still needs to be on duty, and still needs
-- to be standing at the motor pool.
--
-- `ADD COLUMN IF NOT EXISTS` because CI applies every migration twice: the
-- second pass must be a no-op, not error 1060.
--
-- Deliberately no CHECK constraint on either column. There is nothing to check
-- that is not already the application's job -- a role id is a Discord snowflake
-- this database has never seen, and a group key lives in `fpd_permission_groups`
-- whose rows an administrator edits -- and a CHECK here would be the start of
-- the pattern that bit us once already: MariaDB refuses (error 1901) a CHECK
-- that references a column a foreign key sets to NULL, because the delete would
-- then produce a row the CHECK forbids. Both shapes are validated in the route
-- layer, where the officer gets a field error instead of a failed statement.

ALTER TABLE `fpd_fleet`
    -- A permission group key from `fpd_permission_groups`. Deliberately not a
    -- foreign key: a group deleted in the editor must leave the vehicle gated
    -- and undrawable (fail closed), not silently open it to the whole
    -- department the way ON DELETE SET NULL would.
    ADD COLUMN IF NOT EXISTS `required_group` VARCHAR(64) NULL
        COMMENT 'Permission group key; officer must satisfy it. NULL = no group gate'
        AFTER `certification`,

    -- A Discord role id (snowflake). Checked against the role snapshot in
    -- `fpd_discord_members`, which is the only permission source there is
    -- (invariant 2) -- this column just names one role directly instead of
    -- going through a group.
    ADD COLUMN IF NOT EXISTS `required_discord_role` VARCHAR(32) NULL
        COMMENT 'Discord role id; holding it is enough on its own. NULL = no role gate'
        AFTER `required_group`;

-- ============================================================
-- 0004_group_version.sql
-- ============================================================
-- 0004_group_version.sql
--
-- Optimistic locking for the permission group editor (spec 3.5, 4.3).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
-- `fpd_permission_groups` was the only editable record in the schema without a
-- `version` column. Every other one -- persons, organisations, notes, cases --
-- has carried one since 0001, and the routes that write them refuse a stale
-- write with `conflict`. The group editor had nothing, so two administrators
-- with the screen open silently overwrote each other.
--
-- Silent is the operative word, and it is why this is not cosmetic. An update
-- REPLACES the group's permission set rather than merging into it, so the
-- loser's grants do not survive anywhere: not in the group, and not in the
-- audit trail, where the diff reads as though the winner had deliberately
-- removed them. A revoked permission that nobody revoked is the worst kind of
-- entry to find in an audit log a month later.
--
-- The column does double duty. Beyond guarding its own row, `admin`'s version
-- is taken as the write lock for the permission model as a whole: an edit
-- anywhere in an inheritance chain bumps it, so a second editor that read the
-- chain before that bump is refused rather than committing a state neither
-- author ever saw. That is the check-then-write gap the group routes could not
-- otherwise close, because the escalation check reads the whole model and the
-- write lands one row at a time.
--
-- `IF NOT EXISTS` because a server that took 0.2.0 and ran the seed by hand may
-- already have the column; MariaDB 10.0+ supports it on ADD COLUMN.

ALTER TABLE `fpd_permission_groups`
    ADD COLUMN IF NOT EXISTS `version` INT UNSIGNED NOT NULL DEFAULT 1
        COMMENT 'Optimistic lock. `admin`s row also locks the model as a whole';

-- ============================================================
-- 0005_records.sql
-- ============================================================
-- 0005_records.sql
--
-- Record numbering (`fpd_counters`), the record-level access tables (spec 4.5)
-- and the M2 records core: the master name index, vehicles, firearms and the
-- query log (spec 7.2, 7.3, 7.4, 7.5).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
--
-- =============================================================================
-- WHY `fpd_counters` IS IN THIS FILE, AND WHY IT IS FIRST
-- =============================================================================
--
-- Spec 13.1 has said since the beginning that numbers are "generated from
-- `fpd_counters` inside a transaction with a row lock". The table was never
-- created -- not in 0001, not in 0002 -- so the evidence module did the only
-- other thing available and derived its sequence from the numbers already in
-- the target table:
--
--     INSERT INTO fpd_scenes (scene_number, ...)
--     SELECT CONCAT(?, LPAD(COALESCE(MAX(existing.sequence), 0) + 1, ?, '0')), ...
--       FROM (SELECT CAST(SUBSTRING_INDEX(scene_number, '-', -1) AS UNSIGNED) AS sequence
--               FROM fpd_scenes
--              WHERE agency_id = ? AND scene_number LIKE ?) AS existing
--
-- One statement, so it reads as atomic. It is not, and the reason is worth
-- writing down precisely, because the obvious reading of it is that InnoDB
-- protects us here.
--
-- **Under REPEATABLE READ it mostly does.** Source and target are the same
-- table, so `INSERT ... SELECT` takes shared next-key locks on every row the
-- subquery scans; a second transaction scanning the same range blocks or
-- deadlocks rather than reading the same MAX. Mostly serialised, at the cost of
-- locking every row of the scan.
--
-- **Under READ COMMITTED it does not.** With `binlog_format = ROW` -- which
-- READ COMMITTED requires and which is the default on MariaDB 10.2+ -- InnoDB
-- takes no gap locks and releases non-matching row locks as it goes. The
-- scanning SELECT half of an `INSERT ... SELECT` is then an ordinary consistent
-- read. Two officers who open a scene in the same tick read the same MAX, both
-- compute the same sequence, and `uq_fpd_scenes_number` refuses one of them.
-- The officer sees a failed action at the moment they are standing over a body.
--
-- READ COMMITTED is not a hypothetical. It is the default on several managed
-- MariaDB products, it is what many ESX servers set outright (it is the
-- standard advice for reducing lock contention on a busy `users` table), and
-- **it is not something FredPD can detect and refuse**: the isolation level is
-- a server variable the operator owns.
--
-- So do not assume the isolation level. Allocate from a row that is held under
-- an exclusive lock, which behaves identically under every level:
--
--     INSERT INTO fpd_counters (...) VALUES (..., 1)
--         ON DUPLICATE KEY UPDATE next_value = next_value;   -- ensure + X lock
--     SELECT next_value FROM fpd_counters WHERE ... FOR UPDATE;  -- the lock
--     INSERT INTO <record> (... number ...) VALUES ((SELECT ... FROM fpd_counters ...), ...);
--     UPDATE fpd_counters SET next_value = next_value + 1 WHERE ...;
--
-- all inside one transaction. `server/core/counters.lua` writes exactly those
-- four statements and every module allocates through it.
--
-- Two details in that sequence are deliberate:
--
--   * The seed is `ON DUPLICATE KEY UPDATE`, not `INSERT IGNORE`. On a
--     duplicate, `INSERT IGNORE` takes a *shared* lock on the existing row;
--     the `FOR UPDATE` that follows would then have to upgrade it to exclusive,
--     and two transactions each holding S and each waiting for X is the
--     textbook deadlock. `ON DUPLICATE KEY UPDATE` takes the exclusive lock
--     immediately, so by the time `FOR UPDATE` runs we already hold it.
--   * The `FOR UPDATE` is therefore redundant *for us*, and it stays anyway. It
--     is the statement spec 13.1 names, it costs one primary-key lookup, and it
--     means the correctness of every record number in the suite does not rest
--     on a reader knowing MariaDB's duplicate-key locking by heart.
--
-- The secondary defect is smaller but real: `scene_number LIKE 'LSPD-S-2026-%'`
-- has no index to use, so every allocation scanned a growing fraction of the
-- table. A counter is one primary-key lookup regardless of how many records
-- exist. Section 12's budgets are acceptance criteria, and this was the one
-- write path that got slower every day the server ran.
--
-- The counter is keyed `(agency_id, kind, year)` because that is the scope a
-- number is unique in. `year = 0` means "not year-scoped": a master person
-- number is `P-{######}` with no year in it (Appendix D), so it counts in one
-- unbroken sequence per agency.
--
--
-- =============================================================================
-- HOT FILES: DERIVED, NOT STORED
-- =============================================================================
--
-- Spec 7.2 requires a hot-file check on every query result: active warrants,
-- BOLOs, stolen vehicle, stolen firearm, protection orders, officer-safety
-- cautions. There are two ways to do that, and this file chooses one.
--
-- **There is no `fpd_hot_files` table.** A hit is derived, at query time, from
-- the record that is the truth for it: `fpd_vehicle_flags` for a stolen or
-- wanted vehicle, `fpd_firearms.status` for a stolen firearm,
-- `fpd_person_cautions` for officer safety -- and, when M2 adds them,
-- `fpd_warrants` and `fpd_bolos` for the other two. Each source is indexed on
-- exactly the columns the check reads, so a check is a point lookup.
--
-- The reason is not normalisation for its own sake. A hot-file table is a
-- *copy*, and a copy has a window in which it disagrees with the record it was
-- copied from. The failure that window produces is not a stale screen: it is an
-- officer told at the roadside that a recalled warrant is active, drawing on
-- somebody over a hit that no longer exists. Every write path that could ever
-- clear a hit -- a warrant recall, a BOLO cancel, a vehicle recovered, a
-- caution expiring by its own `expires_at` with nobody touching the row --
-- would have to remember to maintain the copy, and the one that forgets is
-- discovered by the person it points a gun at.
--
-- Expiry is the clearest case. `fpd_person_cautions.expires_at` stops being a
-- hit at a moment when no statement runs at all. Derivation gets that right for
-- free; a materialised table needs a sweeper, and a sweeper that dies leaves
-- hits standing.
--
-- If section 12's 150 ms query budget is ever missed, the fix is a covering
-- index on the source, and only after that a materialised table fed by the
-- writes themselves. The trade is availability of the truth against latency,
-- and at this size latency is not the problem.
--
--
-- =============================================================================
-- MARIADB GOTCHAS ALREADY LEARNED, AND ONE NEW ONE
-- =============================================================================
--
-- **Error 1901** (0002, `fpd_forensic_index`): a CHECK constraint may never
-- reference a column that a foreign key sets to NULL. MariaDB refuses the DDL
-- outright, because the cascade would otherwise produce a row the CHECK
-- forbids. Every `ON DELETE SET NULL` below therefore points at a column no
-- CHECK in this file mentions -- `fpd_vehicles.owner_person_id`,
-- `fpd_firearms.owner_person_id` -- and the CHECKs that do exist
-- (`fpd_person_cautions.field_key`, `fpd_query_log.reason`) sit on columns no
-- foreign key touches at all.
--
-- **SET NULL cannot be composite here.** Several child tables below use a
-- composite foreign key `(person_id, agency_id) -> fpd_persons (id, agency_id)`
-- so the database itself guarantees a child cannot drift into another agency.
-- That shape is only available with `ON DELETE CASCADE`: `SET NULL` would have
-- to null `agency_id` too, and MariaDB refuses a `SET NULL` foreign key over a
-- `NOT NULL` column. Owner links, which must survive the owner being deleted,
-- are therefore single-column foreign keys.
--
-- **`IF NOT EXISTS` everywhere.** CI applies every migration twice against the
-- same database; the second pass must be a no-op rather than error 1050. The
-- backfill at the end is idempotent for the same reason -- it is an upsert
-- guarded by `GREATEST`, so re-running it can only ever leave the counter where
-- it already was.
--
--
-- =============================================================================
-- TWO THINGS THIS FILE DELIBERATELY DOES *NOT* DO
-- =============================================================================
--
-- **No `sealed` column on a record.** `server/modules/access/repo.lua` reads
-- the sealed flag from `fpd_record_seals` (a live seal is a row with
-- `lifted_at IS NULL`) and sets `row.sealed` itself before the service sees the
-- row. A `sealed` column beside it would be a second source of truth that
-- `attachControl` overwrites on every read -- right up until some other query
-- reads the column instead and disagrees with the access module about whether a
-- court has sealed a file. A seal is also an event with an author, a date, a
-- case number and a lift: a boolean cannot hold that, and the audit question
-- ("who sealed this, and when was it lifted?") has to be answerable.
--
-- **No `compartments` column on a record.** Same reason, and the access module
-- is explicit about it: compartments live in `fpd_record_compartments`, keyed
-- `(record_type, record_id)`, so no query in that module ever interpolates a
-- table name. `classification` *is* a column on each record -- spec 13.1 says
-- so, and the owning module selects it as part of its row and hands the row to
-- `Repo.read`/`Repo.filterSearch`.
--
-- `fpd_record_compartments` and `fpd_record_grants` are consequently the only
-- tables in this file without an `agency_id`. They hang off a record that is
-- itself agency-scoped, and the writes in `access/repo.lua` do not carry one;
-- adding a column the owning module never populates would be a NOT NULL
-- violation on the first grant.
--
-- `fpd_person_index` from spec 13.2 is not created either: the phonetic and
-- partial-match index it describes is three generated columns on `fpd_persons`
-- (`name_normalized`, `soundex_first`, `soundex_last`), which cannot fall out
-- of step with the names they are derived from because the database computes
-- them. A separate index table maintained by the application can.


-- =============================================================================
-- COUNTERS (spec 13.1, Appendix D)
-- =============================================================================

-- One row per (agency, kind, year). `next_value` is the number the *next*
-- record of that kind will carry, so a fresh row starts at 1 and the first
-- record allocated is number 1.
--
-- Deliberately no CHECK on `kind`. The allowlist lives in
-- `server/core/counters.lua`, where an unknown kind fails loudly at the call
-- site with a name in the message; a CHECK here would mean that adding a record
-- type -- a citation, a booking, an impound -- required an ALTER in a new
-- migration before the first one could be written. Migrations are append-only
-- (invariant 8), so that cost is permanent, and it buys nothing: nothing but
-- FredPD writes this table, and a typo'd kind produces its own sequence rather
-- than a duplicate number.
CREATE TABLE IF NOT EXISTS `fpd_counters` (
    `agency_id`  VARCHAR(32)     NOT NULL,
    `kind`       VARCHAR(24)     NOT NULL COMMENT 'person, report, case, warrant, bolo, scene, evidence, …',
    -- 0 means the sequence is not year-scoped (Appendix D: a person number has
    -- no year in it). Anything else is the four-digit year in the number.
    `year`       SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    `next_value` BIGINT UNSIGNED NOT NULL DEFAULT 1 COMMENT 'The number the next record will take',
    `updated_at` DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    -- Composite primary key, so an allocation is one primary-key lookup and the
    -- row it locks is the only row it touches. Two agencies, two kinds or two
    -- years never contend with each other.
    PRIMARY KEY (`agency_id`, `kind`, `year`),
    CONSTRAINT `fk_fpd_counters_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_counters_next` CHECK (`next_value` >= 1)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;


-- =============================================================================
-- RECORD-LEVEL ACCESS (spec 4.5)
--
-- The shape here is dictated by `server/modules/access/repo.lua`, which is the
-- only file that reads or writes any of it. Column names below match the
-- statements in that file exactly; changing one without changing the other
-- breaks access control silently, which is the worst way for it to break.
-- =============================================================================

-- The compartments this server knows about, and what a reader who is refused by
-- one is shown.
--
-- `stub_mode` is `stub` or `hidden`. `contact_unit` is a **key**, not a
-- sentence: the NUI renders `access.unit.<contact_unit>` (invariant 6). A
-- compartment whose stub says "contact the intelligence unit" tells the reader
-- the record exists, which for `intelligence` and `sources` is the one fact
-- that must not leak -- so those two ship as `hidden`.
--
-- An empty table is safe: `Repo.reloadConfig` keeps the shipped defaults when
-- it finds no rows, rather than falling back to a policy that hides everything.
CREATE TABLE IF NOT EXISTS `fpd_compartments` (
    `key`          VARCHAR(32)  NOT NULL COMMENT 'narcotics, homicide, sources, … also the locale key',
    `stub_mode`    VARCHAR(8)   NOT NULL DEFAULT 'hidden',
    `contact_unit` VARCHAR(32)  NULL COMMENT 'Locale key for access.unit.<x>, never a sentence',
    `enabled`      TINYINT(1)   NOT NULL DEFAULT 1,
    `created_at`   DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`key`),
    CONSTRAINT `ck_fpd_compartments_stub` CHECK (`stub_mode` IN ('stub', 'hidden'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- The same choice per classification level.
--
-- No `rank` column: the order of the five levels is the security model and it
-- lives in `Access.LEVELS`, where busted tests it. A rank in the database would
-- be a second definition of the scale that an administrator could edit into
-- disagreement with the code.
CREATE TABLE IF NOT EXISTS `fpd_classifications` (
    `level`     VARCHAR(16) NOT NULL,
    `stub_mode` VARCHAR(8)  NOT NULL DEFAULT 'stub',

    PRIMARY KEY (`level`),
    CONSTRAINT `ck_fpd_classifications_level` CHECK (`level` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret')),
    CONSTRAINT `ck_fpd_classifications_stub` CHECK (`stub_mode` IN ('stub', 'hidden'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Which compartments a record is in. Polymorphic by design: `record_type` is
-- checked against a fixed allowlist in `access/repo.lua`, which is what lets
-- that module hold every record's access control without ever naming a table.
--
-- `record_id` is deliberately not a foreign key -- it cannot be, it points at
-- twenty different tables. The consequence is that deleting a record leaves its
-- compartment rows behind; that is the safe direction (an orphan row grants
-- nobody anything), and the retention job sweeps them.
CREATE TABLE IF NOT EXISTS `fpd_record_compartments` (
    `record_type`  VARCHAR(24)     NOT NULL,
    `record_id`    BIGINT UNSIGNED NOT NULL,
    `compartment`  VARCHAR(32)     NOT NULL,
    `created_by`   VARCHAR(32)     NULL COMMENT 'Discord id',
    `created_at`   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    -- The primary key is also the batch-read index: `attachControl` asks for
    -- one record type and a list of ids at a time.
    PRIMARY KEY (`record_type`, `record_id`, `compartment`),
    KEY `idx_fpd_record_compartments_name` (`compartment`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Explicit grants: one user (by Discord id) or one Discord role, with an
-- expiry (spec 4.5, and the reason 4.5 bothers to mention one -- an
-- investigator lent a file for a week is not thereby cleared for the
-- compartment it sits in).
--
-- The primary key is what makes `Repo.grant`'s `ON DUPLICATE KEY UPDATE` work:
-- re-granting the same subject extends the existing grant instead of stacking a
-- second row that nobody would think to revoke.
--
-- `expires_at IS NULL` is a grant that does not lapse. That is legitimate -- a
-- case owner's own grant -- and it is why expiry is nullable rather than
-- defaulted to something far away.
CREATE TABLE IF NOT EXISTS `fpd_record_grants` (
    `record_type`  VARCHAR(24)     NOT NULL,
    `record_id`    BIGINT UNSIGNED NOT NULL,
    `subject_type` VARCHAR(8)      NOT NULL COMMENT 'user (Discord id) or role (Discord role id)',
    `subject_id`   VARCHAR(32)     NOT NULL,
    `expires_at`   DATETIME(3)     NULL COMMENT 'NULL never lapses',
    `granted_by`   VARCHAR(32)     NULL COMMENT 'Discord id',
    `granted_at`   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`record_type`, `record_id`, `subject_type`, `subject_id`),
    -- "What am I holding, and what lapses tonight" -- the access panel, and the
    -- retention sweep over dead grants.
    KEY `idx_fpd_record_grants_subject` (`subject_type`, `subject_id`, `expires_at`),
    CONSTRAINT `ck_fpd_record_grants_subject` CHECK (`subject_type` IN ('user', 'role'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Court seals (spec 4.5). A row, not a flag: a seal has an author, a date, a
-- case number and -- when a court lifts it -- a lift with its own author, date
-- and reason. Unsealing stamps the row rather than deleting it, because "this
-- file was sealed between March and July" is a question a court asks.
--
-- `live_seal` is the one trick in this file. A plain unique index on
-- `(record_type, record_id, lifted_at)` would not enforce one live seal per
-- record: NULLs are distinct in a MariaDB unique index, so every lifted seal
-- would also be unique and every *live* one would be too. Generating a column
-- that is 1 while the seal is live and NULL once it is lifted inverts that --
-- lifted rows stop colliding, live rows collide with each other -- so the
-- database, and not a check-then-insert in Lua, is what stops two courts
-- sealing the same file twice.
CREATE TABLE IF NOT EXISTS `fpd_record_seals` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `record_type` VARCHAR(24)     NOT NULL,
    `record_id`   BIGINT UNSIGNED NOT NULL,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `case_number` VARCHAR(32)     NULL,
    `reason`      VARCHAR(512)    NULL,
    `sealed_by`   VARCHAR(32)     NOT NULL COMMENT 'Discord id',
    `sealed_at`   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `lifted_at`   DATETIME(3)     NULL,
    `lifted_by`   VARCHAR(32)     NULL,
    `lift_reason` VARCHAR(512)    NULL,

    `live_seal`   TINYINT UNSIGNED AS (CASE WHEN `lifted_at` IS NULL THEN 1 ELSE NULL END) STORED,

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_record_seals_live` (`record_type`, `record_id`, `live_seal`),
    KEY `idx_fpd_record_seals_agency` (`agency_id`, `sealed_at`),
    CONSTRAINT `fk_fpd_record_seals_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Break-glass access (spec 4.5): thirty minutes, with a written reason, audited
-- and notified. The reason is the control, so it is NOT NULL here as well as
-- length-checked in the repo -- break-glass is not a permission to read
-- everything, it is a permission to read one record now and answer for it
-- afterwards.
--
-- Rows are never updated. An expired entry is history, and the retention job is
-- what eventually removes it.
CREATE TABLE IF NOT EXISTS `fpd_breakglass` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `discord_id`  VARCHAR(32)     NOT NULL,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `record_type` VARCHAR(24)     NOT NULL,
    `record_id`   BIGINT UNSIGNED NOT NULL,
    `reason`      VARCHAR(512)    NOT NULL,
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `expires_at`  DATETIME(3)     NOT NULL,

    PRIMARY KEY (`id`),
    -- Exactly the lookup `attachGrants` makes: this reader, this record type,
    -- these ids, still live.
    KEY `idx_fpd_breakglass_live` (`discord_id`, `record_type`, `record_id`, `expires_at`),
    KEY `idx_fpd_breakglass_agency` (`agency_id`, `created_at`),
    CONSTRAINT `fk_fpd_breakglass_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;


-- =============================================================================
-- MASTER NAME INDEX (spec 7.3)
-- =============================================================================

-- One row per person known to an agency.
--
-- Identity comes from the framework -- `identifier` is the ESX character
-- identifier, the same key `fpd_biometrics` uses -- and everything else is
-- FredPD's own. `identifier` is nullable because a person can enter the index
-- before anyone knows who they are: a name given at a scene, a booking of
-- somebody carrying no identification. Those rows are joined to a character
-- later, which is why the uniqueness below is on `(agency_id, identifier)`
-- rather than on `identifier` alone -- NULLs are distinct in a MariaDB unique
-- index, so any number of unidentified persons coexist while a character can
-- still only have one master record per agency.
--
-- **Phonetic search (7.2).** `name_normalized`, `soundex_first` and
-- `soundex_last` are generated columns, so they cannot fall out of step with
-- the names they come from -- an application-maintained index can, and the day
-- it does is the day a wanted person stops being findable. `soundex_*` are
-- separate per name part rather than one code over the whole string: SOUNDEX
-- collapses a whole string into one code, so "Johansson Karl" and
-- "Karl Johansson" would not match each other, and a query wants
-- `soundex_last = SOUNDEX(?)` to be an index seek.
--
-- **No `sealed` and no `compartments` column.** See the file header: both live
-- in the generic access tables above, where `access/repo.lua` puts them.
CREATE TABLE IF NOT EXISTS `fpd_persons` (
    `id`            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`     VARCHAR(32)     NOT NULL,
    `person_number` VARCHAR(32)     NOT NULL COMMENT 'P-000431. Allocated from fpd_counters',

    `identifier`    VARCHAR(191)    NULL COMMENT 'ESX character identifier, NULL until identified',

    `first_name`    VARCHAR(96)     NULL,
    `middle_name`   VARCHAR(96)     NULL,
    `last_name`     VARCHAR(96)     NULL,
    `date_of_birth` DATE            NULL,
    `sex`           VARCHAR(16)     NULL,
    `phone`         VARCHAR(32)     NULL,
    -- Free text until 7.6 owns `fpd_addresses`. A person's address is a
    -- redactable field (`fields.victim_address.view`), enforced in the module.
    `address`       VARCHAR(191)    NULL,

    `deceased_at`   DATETIME(3)     NULL COMMENT '7.3: deceased flag',
    `missing_since` DATETIME(3)     NULL COMMENT '7.3: missing-person status',

    `classification` VARCHAR(16)    NOT NULL DEFAULT 'internal',
    `version`       INT UNSIGNED    NOT NULL DEFAULT 1 COMMENT 'Optimistic lock (spec 13.1)',
    `created_by`    VARCHAR(32)     NULL COMMENT 'Discord id',
    `created_at`    DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_by`    VARCHAR(32)     NULL,
    `updated_at`    DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    -- Wide enough for three 96-character names and the two separators between
    -- them. A generated column whose expression overflows its own type is an
    -- error on INSERT under strict mode, not a truncation -- so the width here
    -- is arithmetic, not taste.
    `name_normalized` VARCHAR(320)
        AS (LOWER(TRIM(CONCAT_WS(' ', `first_name`, `middle_name`, `last_name`)))) STORED,
    -- Same reason, and it is why these are not CHAR(4). MariaDB's SOUNDEX is
    -- not truncated to four characters: it emits the initial letter plus one
    -- digit per remaining consonant, so a long name produces a long code. The
    -- full code is stored rather than `LEFT(SOUNDEX(x), 4)` so that a query can
    -- be written `soundex_last = SOUNDEX(?)` without every caller having to
    -- remember to truncate its own side to match.
    `soundex_first` VARCHAR(128)    AS (SOUNDEX(`first_name`)) STORED,
    `soundex_last`  VARCHAR(128)    AS (SOUNDEX(`last_name`)) STORED,

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_persons_number` (`agency_id`, `person_number`),
    UNIQUE KEY `uq_fpd_persons_identifier` (`agency_id`, `identifier`),
    -- The target of the composite foreign keys on the child tables below. It is
    -- what makes "a person's alias belongs to the same agency as the person"
    -- something the database enforces rather than something the repo remembers.
    UNIQUE KEY `uq_fpd_persons_id_agency` (`id`, `agency_id`),
    KEY `idx_fpd_persons_name` (`agency_id`, `name_normalized`),
    KEY `idx_fpd_persons_soundex` (`agency_id`, `soundex_last`, `soundex_first`),
    KEY `idx_fpd_persons_dob` (`agency_id`, `date_of_birth`),
    KEY `idx_fpd_persons_phone` (`agency_id`, `phone`),
    CONSTRAINT `fk_fpd_persons_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_persons_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret')),
    CONSTRAINT `ck_fpd_persons_sex` CHECK (`sex` IS NULL OR `sex` IN
        ('male', 'female', 'other', 'unknown'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Aliases and monikers (7.3). Searched exactly like a name, so they carry the
-- same generated phonetic columns -- an alias that could only be found by exact
-- spelling would be the half of the index that quietly does not work.
CREATE TABLE IF NOT EXISTS `fpd_person_aliases` (
    `id`         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`  VARCHAR(32)     NOT NULL,
    `person_id`  BIGINT UNSIGNED NOT NULL,

    `alias`      VARCHAR(191)    NOT NULL,
    `kind`       VARCHAR(16)     NOT NULL DEFAULT 'alias' COMMENT 'alias | moniker | maiden | former',
    `source`     VARCHAR(191)    NULL COMMENT 'Where it came from: a case number, an interview',

    `created_by` VARCHAR(32)     NULL,
    `created_at` DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    -- `alias_soundex` is wider than the alias it comes from for the reason
    -- given on `fpd_persons`: a SOUNDEX code is roughly one character per
    -- consonant and is not cut off at four.
    `alias_normalized` VARCHAR(191) AS (LOWER(TRIM(`alias`))) STORED,
    `alias_soundex`    VARCHAR(255) AS (SOUNDEX(`alias`)) STORED,

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_person_aliases` (`person_id`, `alias_normalized`),
    KEY `idx_fpd_person_aliases_search` (`agency_id`, `alias_normalized`),
    KEY `idx_fpd_person_aliases_soundex` (`agency_id`, `alias_soundex`),
    CONSTRAINT `fk_fpd_person_aliases_person` FOREIGN KEY (`person_id`, `agency_id`)
        REFERENCES `fpd_persons` (`id`, `agency_id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_person_aliases_kind` CHECK (`kind` IN
        ('alias', 'moniker', 'maiden', 'former')),
    CONSTRAINT `ck_fpd_person_aliases_value` CHECK (CHAR_LENGTH(TRIM(`alias`)) > 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- The physical description (7.3). One row per person: this is what the person
-- looks like now, not a history of what they looked like. Scars, marks and
-- tattoos are photographs with a body location, so they live in
-- `fpd_person_photos` where the photo does.
--
-- Heights are centimetres and weights kilograms, stored as integers. A unit
-- suffix in a string column is the kind of thing that ends up compared
-- lexically.
CREATE TABLE IF NOT EXISTS `fpd_person_descriptors` (
    `person_id`   BIGINT UNSIGNED NOT NULL,
    `agency_id`   VARCHAR(32)     NOT NULL,

    `height_cm`   SMALLINT UNSIGNED NULL,
    `weight_kg`   SMALLINT UNSIGNED NULL,
    `build`       VARCHAR(24)     NULL COMMENT 'Code table value, rendered from a locale key',
    `hair_colour` VARCHAR(24)     NULL,
    `hair_style`  VARCHAR(24)     NULL,
    `eye_colour`  VARCHAR(24)     NULL,
    `complexion`  VARCHAR(24)     NULL,
    `glasses`     TINYINT(1)      NOT NULL DEFAULT 0,
    `notes`       VARCHAR(512)    NULL,

    `updated_by`  VARCHAR(32)     NULL,
    `updated_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`person_id`),
    KEY `idx_fpd_person_descriptors_agency` (`agency_id`),
    CONSTRAINT `fk_fpd_person_descriptors_person` FOREIGN KEY (`person_id`, `agency_id`)
        REFERENCES `fpd_persons` (`id`, `agency_id`) ON DELETE CASCADE,
    -- Bounds a typo cannot get past. 30 cm and 400 kg are absurd; 250 cm and
    -- 300 kg are not, and the constraint is there to catch a slipped decimal
    -- point rather than to have an opinion about anybody.
    CONSTRAINT `ck_fpd_person_descriptors_height` CHECK (
        `height_cm` IS NULL OR (`height_cm` BETWEEN 50 AND 280)),
    CONSTRAINT `ck_fpd_person_descriptors_weight` CHECK (
        `weight_kg` IS NULL OR (`weight_kg` BETWEEN 20 AND 400))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Photo history: mugshots, field photos and the photographs of scars, marks and
-- tattoos that 7.3 asks for.
--
-- `media_ref` is a reference into the media store, never a URL and never a
-- path a browser could fetch directly. Media reaches the NUI through the
-- gateway with a signed URL and the NUI's own CSP (invariant 9); a column
-- holding a fetchable address would make that machinery optional.
CREATE TABLE IF NOT EXISTS `fpd_person_photos` (
    `id`            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`     VARCHAR(32)     NOT NULL,
    `person_id`     BIGINT UNSIGNED NOT NULL,

    `kind`          VARCHAR(16)     NOT NULL DEFAULT 'mugshot',
    `media_ref`     VARCHAR(191)    NOT NULL COMMENT 'Media store reference, served through the gateway',
    `body_location` VARCHAR(48)     NULL COMMENT 'For a mark, scar or tattoo',
    `description`   VARCHAR(255)    NULL,
    `taken_at`      DATETIME(3)     NULL COMMENT 'When the photograph was taken, not when it was uploaded',
    `source_case`   VARCHAR(32)     NULL,

    `classification` VARCHAR(16)    NOT NULL DEFAULT 'internal',
    `created_by`    VARCHAR(32)     NULL,
    `created_at`    DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    KEY `idx_fpd_person_photos_person` (`person_id`, `kind`, `taken_at`),
    KEY `idx_fpd_person_photos_agency` (`agency_id`, `created_at`),
    CONSTRAINT `fk_fpd_person_photos_person` FOREIGN KEY (`person_id`, `agency_id`)
        REFERENCES `fpd_persons` (`id`, `agency_id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_person_photos_kind` CHECK (`kind` IN
        ('mugshot', 'field', 'scar', 'mark', 'tattoo')),
    CONSTRAINT `ck_fpd_person_photos_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Cautions and flags (7.3), with expiry.
--
-- These are what a query result turns red for, so the index below is the one
-- the hot-file check reads: person, live, by kind.
--
-- **Mental health is a restricted field, not a restricted record.** The
-- distinction matters and the schema enforces it rather than trusting a writer
-- to remember: `field_key` names the `fields.<key>.view` permission a reader
-- must hold for the *detail* of this caution, and the CHECK makes a
-- mental-health caution without that key impossible to insert. The caution
-- itself is still visible -- an officer must know to send a crisis team rather
-- than a rifle -- while the diagnosis behind it is not. Redaction applies to
-- prints and exports the same way (4.5).
CREATE TABLE IF NOT EXISTS `fpd_person_cautions` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `person_id`   BIGINT UNSIGNED NOT NULL,

    `kind`        VARCHAR(24)     NOT NULL,
    `detail`      VARCHAR(512)    NULL COMMENT 'Redacted unless the reader holds fields.<field_key>.view',
    `field_key`   VARCHAR(32)     NULL COMMENT 'fields.<field_key>.view gates `detail`',
    `source_case` VARCHAR(32)     NULL,

    `classification` VARCHAR(16)  NOT NULL DEFAULT 'internal',
    `expires_at`  DATETIME(3)     NULL COMMENT 'NULL does not expire. A past value is not a caution',
    `cancelled_at` DATETIME(3)    NULL,
    `cancelled_by` VARCHAR(32)    NULL,
    `created_by`  VARCHAR(32)     NULL,
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    KEY `idx_fpd_person_cautions_live` (`person_id`, `cancelled_at`, `expires_at`),
    KEY `idx_fpd_person_cautions_kind` (`agency_id`, `kind`, `expires_at`),
    CONSTRAINT `fk_fpd_person_cautions_person` FOREIGN KEY (`person_id`, `agency_id`)
        REFERENCES `fpd_persons` (`id`, `agency_id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_person_cautions_kind` CHECK (`kind` IN
        ('armed', 'violent', 'officer_safety', 'mental_health', 'gang')),
    CONSTRAINT `ck_fpd_person_cautions_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret')),
    -- Safe from error 1901: no foreign key writes `field_key` or `kind`.
    CONSTRAINT `ck_fpd_person_cautions_field` CHECK (
        `kind` <> 'mental_health' OR `field_key` = 'mental_health')
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- "Fingerprints on file" and "DNA on file" (7.3) -- and nothing else.
--
-- **This table never holds a biometric value.** Read that again before adding a
-- column to it. The actual DNA profile and fingerprint live in `fpd_biometrics`
-- (migration 0002), they are opaque, they are compared inside the database and
-- they never leave the server (8.1, 8.11). What an officer reading a person's
-- file may know is that a sample exists, when it was taken and which index it
-- was filed in -- which is exactly what a real records system shows, and which
-- is what makes a lab comparison a *lead* rather than a lookup.
--
-- `index_name` matches `fpd_forensic_index.index_kind`, so "DNA on file
-- (offender index, 2026-03-14)" points at a real entry an analyst can act on.
CREATE TABLE IF NOT EXISTS `fpd_person_biometrics_index` (
    `person_id`   BIGINT UNSIGNED NOT NULL,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `kind`        VARCHAR(16)     NOT NULL COMMENT 'fingerprint | dna',

    `on_file`     TINYINT(1)      NOT NULL DEFAULT 0,
    `index_name`  VARCHAR(24)     NULL COMMENT 'Matches fpd_forensic_index.index_kind',
    `recorded_on` DATE            NULL,
    `recorded_by` VARCHAR(32)     NULL,
    `updated_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`person_id`, `kind`),
    KEY `idx_fpd_person_biometrics_agency` (`agency_id`, `kind`, `on_file`),
    CONSTRAINT `fk_fpd_person_biometrics_person` FOREIGN KEY (`person_id`, `agency_id`)
        REFERENCES `fpd_persons` (`id`, `agency_id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_person_biometrics_kind` CHECK (`kind` IN ('fingerprint', 'dna'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;


-- =============================================================================
-- VEHICLES (spec 7.4)
-- =============================================================================

-- Registration comes from the garage bridge; the VIN is generated once and
-- stored, because a VIN that is derived on read would change the day the
-- derivation changes and every report quoting the old one would be wrong.
--
-- `owner_person_id` is a single-column foreign key with `ON DELETE SET NULL`,
-- not the composite used by the person child tables. A composite would have to
-- null `agency_id` as well, and MariaDB refuses a `SET NULL` foreign key over a
-- `NOT NULL` column. The consequence is that the owning agency of a vehicle is
-- its own, and the repo checks that an owner it links belongs to the same one.
CREATE TABLE IF NOT EXISTS `fpd_vehicles` (
    `id`            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`     VARCHAR(32)     NOT NULL,

    `plate`         VARCHAR(16)     NOT NULL COMMENT 'Current plate, upper-cased on write',
    `vin`           VARCHAR(24)     NULL COMMENT 'Generated once and stored (7.4)',
    `model`         VARCHAR(64)     NULL COMMENT 'Spawn name. The label is a locale key',
    `colour`        VARCHAR(32)     NULL,
    `colour_secondary` VARCHAR(32)  NULL,

    `owner_person_id`  BIGINT UNSIGNED NULL,
    `owner_identifier` VARCHAR(191)    NULL COMMENT 'ESX character identifier of the registered keeper',

    `registration_status` VARCHAR(16) NOT NULL DEFAULT 'valid',
    `registration_expires` DATE       NULL,
    `insurance_status`    VARCHAR(16) NOT NULL DEFAULT 'none',
    `insurance_expires`   DATE        NULL,

    `classification` VARCHAR(16)    NOT NULL DEFAULT 'internal',
    `version`       INT UNSIGNED    NOT NULL DEFAULT 1,
    `created_by`    VARCHAR(32)     NULL,
    `created_at`    DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_by`    VARCHAR(32)     NULL,
    `updated_at`    DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_vehicles_plate` (`agency_id`, `plate`),
    UNIQUE KEY `uq_fpd_vehicles_vin` (`agency_id`, `vin`),
    UNIQUE KEY `uq_fpd_vehicles_id_agency` (`id`, `agency_id`),
    KEY `idx_fpd_vehicles_owner` (`owner_person_id`),
    KEY `idx_fpd_vehicles_identifier` (`agency_id`, `owner_identifier`),
    CONSTRAINT `fk_fpd_vehicles_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    -- A vehicle outlives the person record that owned it: an expunged person
    -- must not take the car out of the register with them.
    CONSTRAINT `fk_fpd_vehicles_owner` FOREIGN KEY (`owner_person_id`)
        REFERENCES `fpd_persons` (`id`) ON DELETE SET NULL,
    CONSTRAINT `ck_fpd_vehicles_registration` CHECK (`registration_status` IN
        ('valid', 'expired', 'suspended', 'revoked', 'unregistered')),
    CONSTRAINT `ck_fpd_vehicles_insurance` CHECK (`insurance_status` IN
        ('valid', 'expired', 'none')),
    CONSTRAINT `ck_fpd_vehicles_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret')),
    CONSTRAINT `ck_fpd_vehicles_plate` CHECK (CHAR_LENGTH(TRIM(`plate`)) > 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Plate history (7.4). Append-only: a plate change is an event, and the whole
-- reason to keep it is that a witness three weeks ago read the *old* plate.
-- The index on `plate` is therefore the point of the table -- a query for a
-- plate nobody carries any more still finds the vehicle.
CREATE TABLE IF NOT EXISTS `fpd_vehicle_plates` (
    `id`         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`  VARCHAR(32)     NOT NULL,
    `vehicle_id` BIGINT UNSIGNED NOT NULL,

    `plate`      VARCHAR(16)     NOT NULL,
    `held_from`  DATETIME(3)     NULL,
    `held_until` DATETIME(3)     NULL COMMENT 'NULL while it is the current plate',
    `reason`     VARCHAR(191)    NULL,

    `created_by` VARCHAR(32)     NULL,
    `created_at` DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    KEY `idx_fpd_vehicle_plates_plate` (`agency_id`, `plate`),
    KEY `idx_fpd_vehicle_plates_vehicle` (`vehicle_id`, `held_until`),
    CONSTRAINT `fk_fpd_vehicle_plates_vehicle` FOREIGN KEY (`vehicle_id`, `agency_id`)
        REFERENCES `fpd_vehicles` (`id`, `agency_id`) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Vehicle flags (7.4), and one of the hot-file sources the header describes.
--
-- A flag is cleared by stamping `cleared_at`, never by deleting the row: "this
-- car was reported stolen in March and recovered in April" is the history a
-- report is written from. The live-flag index is the hot-file lookup.
CREATE TABLE IF NOT EXISTS `fpd_vehicle_flags` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `vehicle_id`  BIGINT UNSIGNED NOT NULL,

    `kind`        VARCHAR(24)     NOT NULL,
    `detail`      VARCHAR(512)    NULL,
    `case_number` VARCHAR(32)     NULL,

    `classification` VARCHAR(16)  NOT NULL DEFAULT 'internal',
    `expires_at`  DATETIME(3)     NULL,
    `cleared_at`  DATETIME(3)     NULL,
    `cleared_by`  VARCHAR(32)     NULL,
    `created_by`  VARCHAR(32)     NULL,
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    KEY `idx_fpd_vehicle_flags_live` (`vehicle_id`, `cleared_at`, `expires_at`),
    KEY `idx_fpd_vehicle_flags_kind` (`agency_id`, `kind`, `cleared_at`),
    CONSTRAINT `fk_fpd_vehicle_flags_vehicle` FOREIGN KEY (`vehicle_id`, `agency_id`)
        REFERENCES `fpd_vehicles` (`id`, `agency_id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_vehicle_flags_kind` CHECK (`kind` IN
        ('stolen', 'wanted', 'bolo', 'impounded', 'evidence_hold', 'uninsured')),
    CONSTRAINT `ck_fpd_vehicle_flags_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;


-- =============================================================================
-- FIREARMS REGISTRY (spec 7.5)
-- =============================================================================

-- **No foreign key to `fpd_weapon_signatures`,** although both are keyed by
-- serial. That table is hidden truth (8.1): it holds the barrel signature that
-- links a casing to the gun that fired it, and the only code allowed to join it
-- is the lab path in `evidence/repo.lua`. A declared relationship here would
-- invite a join in a client-facing read, and one `SELECT *` later the ballistic
-- signature is on an officer's screen. The registry and the signature meet in
-- the lab or not at all.
--
-- `status = 'agency_issued'` with `assigned_officer` set is a duty weapon
-- (7.5). Recovering one from a crime scene should be as traceable as any other
-- firearm, which is why it is a status on the same table rather than a
-- separate armoury.
CREATE TABLE IF NOT EXISTS `fpd_firearms` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,

    `serial`      VARCHAR(64)     NOT NULL,
    `make`        VARCHAR(64)     NULL,
    `model`       VARCHAR(64)     NULL,
    `type`        VARCHAR(24)     NULL,
    `calibre`     VARCHAR(24)     NULL,
    `status`      VARCHAR(24)     NOT NULL DEFAULT 'registered',

    `owner_person_id`  BIGINT UNSIGNED NULL,
    `owner_identifier` VARCHAR(191)    NULL,
    `assigned_officer` VARCHAR(32)     NULL COMMENT 'Discord id, for an agency-issued weapon',

    `classification` VARCHAR(16)  NOT NULL DEFAULT 'internal',
    `version`     INT UNSIGNED    NOT NULL DEFAULT 1,
    `created_by`  VARCHAR(32)     NULL,
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_by`  VARCHAR(32)     NULL,
    `updated_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_firearms_serial` (`agency_id`, `serial`),
    UNIQUE KEY `uq_fpd_firearms_id_agency` (`id`, `agency_id`),
    KEY `idx_fpd_firearms_owner` (`owner_person_id`),
    KEY `idx_fpd_firearms_status` (`agency_id`, `status`),
    KEY `idx_fpd_firearms_assigned` (`agency_id`, `assigned_officer`),
    CONSTRAINT `fk_fpd_firearms_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_firearms_owner` FOREIGN KEY (`owner_person_id`)
        REFERENCES `fpd_persons` (`id`) ON DELETE SET NULL,
    CONSTRAINT `ck_fpd_firearms_status` CHECK (`status` IN
        ('registered', 'lost', 'stolen', 'seized', 'destroyed', 'agency_issued')),
    CONSTRAINT `ck_fpd_firearms_type` CHECK (`type` IS NULL OR `type` IN
        ('pistol', 'revolver', 'rifle', 'shotgun', 'smg', 'other')),
    CONSTRAINT `ck_fpd_firearms_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret')),
    CONSTRAINT `ck_fpd_firearms_serial` CHECK (CHAR_LENGTH(TRIM(`serial`)) > 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Ownership history and every other event in a firearm's life (7.5).
--
-- Append-only, like the chain of custody in 0002 and for the same reason: a
-- trace report is the reconstruction of this table, from the recovered weapon
-- back to the first purchaser, and a history that can be edited traces nothing.
-- Nothing in the application updates or deletes a row here.
--
-- `from_person_id` and `to_person_id` are plain single-column foreign keys with
-- `SET NULL`: the event survives the person record, and the free-text
-- `from_party`/`to_party` keep the name that was recorded at the time.
CREATE TABLE IF NOT EXISTS `fpd_firearm_events` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `firearm_id`  BIGINT UNSIGNED NOT NULL,

    `event`       VARCHAR(24)     NOT NULL,
    `occurred_at` DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `from_person_id` BIGINT UNSIGNED NULL,
    `to_person_id`   BIGINT UNSIGNED NULL,
    `from_party`  VARCHAR(191)    NULL COMMENT 'Name or dealer as recorded at the time',
    `to_party`    VARCHAR(191)    NULL,
    `case_number` VARCHAR(32)     NULL,
    `reason`      VARCHAR(512)    NULL,
    `recorded_by` VARCHAR(32)     NULL COMMENT 'Discord id',

    PRIMARY KEY (`id`),
    KEY `idx_fpd_firearm_events_firearm` (`firearm_id`, `occurred_at`),
    KEY `idx_fpd_firearm_events_person` (`to_person_id`),
    KEY `idx_fpd_firearm_events_agency` (`agency_id`, `occurred_at`),
    CONSTRAINT `fk_fpd_firearm_events_firearm` FOREIGN KEY (`firearm_id`, `agency_id`)
        REFERENCES `fpd_firearms` (`id`, `agency_id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_firearm_events_from` FOREIGN KEY (`from_person_id`)
        REFERENCES `fpd_persons` (`id`) ON DELETE SET NULL,
    CONSTRAINT `fk_fpd_firearm_events_to` FOREIGN KEY (`to_person_id`)
        REFERENCES `fpd_persons` (`id`) ON DELETE SET NULL,
    CONSTRAINT `ck_fpd_firearm_events_event` CHECK (`event` IN
        ('register', 'transfer', 'lost', 'stolen', 'recovered', 'seized',
         'destroyed', 'issued', 'returned'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;


-- =============================================================================
-- QUERY LOG (spec 7.2, 11.4, 13.3)
-- =============================================================================

-- Every query, whoever ran it and whatever it found. This is the table that
-- answers "who has been looking up their ex-girlfriend's address", which is the
-- single most common real-world misuse of a police records system, and it is
-- why the log records the *term* and not only the record that matched: a search
-- that found nothing is as interesting as one that did.
--
-- `reason` and `case_number` exist because 7.2 requires them: a query into
-- restricted data must carry one. The CHECK is what makes that a property of
-- the data rather than a habit of the caller -- a row marked `restricted` with
-- neither is rejected by the database. Neither column is written by a foreign
-- key, so error 1901 does not apply.
--
-- No foreign key to anything but the agency, deliberately. The log outlives
-- what it points at, a term may match no record at all, and a log that
-- cascade-deletes when a record is expunged is a log that erases the evidence
-- of who read the record before it was expunged.
--
-- Retention: 13.3 sweeps this table per agency policy. The sweep is the only
-- writer that ever deletes from it.
CREATE TABLE IF NOT EXISTS `fpd_query_log` (
    `id`           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`    VARCHAR(32)     NOT NULL,

    `discord_id`   VARCHAR(32)     NOT NULL COMMENT 'From the session, never from input',
    `officer_id`   BIGINT UNSIGNED NULL,
    `identifier`   VARCHAR(191)    NULL COMMENT 'Character the officer was playing',

    `query_type`   VARCHAR(16)     NOT NULL COMMENT 'person | plate | vin | firearm | phone | address',
    `term`         VARCHAR(191)    NOT NULL COMMENT 'What was typed, normalized',
    `access_point` VARCHAR(32)     NULL COMMENT 'mdt, terminal, radio, vehicle (7.2, 1.4)',

    `restricted`   TINYINT(1)      NOT NULL DEFAULT 0 COMMENT 'The query reached restricted data',
    `reason`       VARCHAR(255)    NULL,
    `case_number`  VARCHAR(32)     NULL,

    `result_count` INT UNSIGNED    NOT NULL DEFAULT 0 COMMENT 'Rows the reader was allowed to see',
    `hit_count`    INT UNSIGNED    NOT NULL DEFAULT 0 COMMENT 'Hot-file hits among them',
    `created_at`   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    KEY `idx_fpd_query_log_agency` (`agency_id`, `created_at`),
    -- "Everything this officer has looked at", which is how a misuse complaint
    -- is investigated, and "who looked at this plate", which is how a leak is.
    KEY `idx_fpd_query_log_officer` (`agency_id`, `discord_id`, `created_at`),
    KEY `idx_fpd_query_log_term` (`agency_id`, `query_type`, `term`),
    CONSTRAINT `fk_fpd_query_log_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_query_log_type` CHECK (`query_type` IN
        ('person', 'plate', 'vin', 'firearm', 'phone', 'address')),
    CONSTRAINT `ck_fpd_query_log_reason` CHECK (
        `restricted` = 0 OR `reason` IS NOT NULL OR `case_number` IS NOT NULL)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;


-- =============================================================================
-- BACKFILL: EVIDENCE AND SCENE COUNTERS
--
-- `evidence/repo.lua` stops deriving its sequence from MAX() in this release and
-- starts allocating from `fpd_counters`. A counter that started at 1 on a server
-- that already has evidence would hand out numbers that are already taken, and
-- `uq_fpd_evidence_number` would refuse every one of them until the counter
-- caught up -- which is the same officer-facing failure this migration exists to
-- remove, made worse.
--
-- So seed each counter from the highest number that exists.
--
-- The year is parsed out of the number rather than taken from `collected_at`,
-- because the number is what has to stay unique: the two agree except for a row
-- written in the last seconds of a year, and a mismatch there would leave the
-- new year's counter at 1 with a row already holding number 1. Both formats end
-- `…-<year>-<sequence>` (`LSPD-2026-000123`, `LSPD-S-2026-0042`), so the last
-- two dash-separated parts are the year and the sequence whatever the agency
-- short name contains.
--
-- `next_value` is MAX + 1 because the counter holds the number the *next*
-- record will take.
--
-- Idempotent: `GREATEST` means a second run cannot lower a counter that has
-- moved on since, and on an empty database (CI) both statements insert nothing.
-- =============================================================================

INSERT INTO `fpd_counters` (`agency_id`, `kind`, `year`, `next_value`)
SELECT `agency_id`,
       'evidence',
       CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(`evidence_number`, '-', -2), '-', 1) AS UNSIGNED),
       MAX(CAST(SUBSTRING_INDEX(`evidence_number`, '-', -1) AS UNSIGNED)) + 1
  FROM `fpd_evidence`
 GROUP BY `agency_id`,
          CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(`evidence_number`, '-', -2), '-', 1) AS UNSIGNED)
ON DUPLICATE KEY UPDATE `next_value` = GREATEST(`next_value`, VALUES(`next_value`));

INSERT INTO `fpd_counters` (`agency_id`, `kind`, `year`, `next_value`)
SELECT `agency_id`,
       'scene',
       CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(`scene_number`, '-', -2), '-', 1) AS UNSIGNED),
       MAX(CAST(SUBSTRING_INDEX(`scene_number`, '-', -1) AS UNSIGNED)) + 1
  FROM `fpd_scenes`
 GROUP BY `agency_id`,
          CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(`scene_number`, '-', -2), '-', 1) AS UNSIGNED)
ON DUPLICATE KEY UPDATE `next_value` = GREATEST(`next_value`, VALUES(`next_value`));

-- ============================================================
-- 0006_hotfile_confirmation.sql
-- ============================================================
-- 0006_hotfile_confirmation.sql
--
-- Hot-file hit confirmation (spec 7.2).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
--
-- =============================================================================
-- WHY THIS TABLE EXISTS
-- =============================================================================
--
-- 7.2: "Hits show a red banner and require a confirmation step before the hit
-- is treated as confirmed (real hit-confirmation practice)."
--
-- The practice it names is not decoration. In a real hot file, finding a record
-- is a *lead*: the record may have been cleared an hour ago, the plate may have
-- been re-issued, the person in front of the officer may not be the person in
-- the file. So the finding agency asks the agency holding the record, and the
-- answer -- confirmed, no longer valid, or nobody could be reached in time --
-- comes back separately and is what an arrest is made on.
--
-- FredPD keeps the distinction because of what happens afterwards. An officer
-- who stopped a car on an unconfirmed stolen-vehicle flag has done something a
-- department is asked about, sometimes in court, and the only way to answer is
-- a record of whether the confirmation happened *before* the stop. A boolean on
-- the flag could not: it would say the flag is confirmed, not that this officer
-- confirmed this lead at this moment.
--
-- Hence a row per confirmation rather than a column on the hit, and hence the
-- binding to `fpd_query_log`: a confirmation belongs to the query that raised
-- the lead. Re-running the query raises a fresh, unconfirmed lead, which is
-- correct -- a confirmation is good for the encounter it was taken for and not
-- for ever.
--
--
-- =============================================================================
-- WHAT THIS TABLE DELIBERATELY DOES NOT HAVE
-- =============================================================================
--
-- **No foreign key on `hit_id`.** A hit is a vehicle flag, a firearm or a
-- person caution, so the key is `(hit_type, hit_id)` across three tables and no
-- single foreign key can express it. This is the same shape the access tables
-- use (`fpd_record_compartments`, keyed `(record_type, record_id)`) and for the
-- same reason: the alternative is three nullable columns and three keys, where
-- every read has to work out which one is populated and a row can name two hits
-- at once.
--
-- The consequence is that a deleted flag leaves its confirmation behind, and
-- that is wanted rather than tolerated: the register clears flags by stamping
-- them (`cleared_at`) precisely so history survives, and a confirmation is
-- evidence of what an officer was told at the time, which does not stop being
-- true when the flag is lifted.
--
-- **No `agency_id` on the hit's own record.** `agency_id` here is the agency
-- that *confirmed*, which is the session's (invariant 1). The record being
-- confirmed carries its own, and cross-agency reads go through the access
-- module rather than through a column here.
--
-- **No `confirmed` boolean.** `outcome` has three values, because the real
-- answer has three and collapsing `unable` into `not_confirmed` loses the
-- distinction the whole table exists to record: whether anybody answered.
--
-- `IF NOT EXISTS`, because CI applies every migration twice against the same
-- database and the second pass must be a no-op rather than error 1050.


CREATE TABLE IF NOT EXISTS `fpd_hotfile_confirmations` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL COMMENT 'The confirming agency, from the session',

    -- The query that raised the lead (7.2). Nullable: a hit can also be
    -- confirmed from a record page, where no query ran. `SET NULL` on delete,
    -- so the retention sweep over `fpd_query_log` (13.3) cannot take the
    -- confirmation with it -- the confirmation outlives the search that found
    -- it, which is the point of keeping it.
    `query_id`    BIGINT UNSIGNED NULL,

    -- Which hot file, and which row in it. No foreign key: see the header.
    `hit_type`    VARCHAR(24)     NOT NULL COMMENT 'vehicle_flag | firearm | person_caution',
    `hit_id`      BIGINT UNSIGNED NOT NULL COMMENT 'The flag, firearm or caution row',
    `hit_kind`    VARCHAR(24)     NOT NULL COMMENT 'Read off the record: stolen, bolo, armed, …',

    -- The record the hit sits on, so "every confirmation on this vehicle" is a
    -- key lookup rather than a join through three tables.
    `record_type` VARCHAR(16)     NOT NULL COMMENT 'vehicle | firearm | person',
    `record_id`   BIGINT UNSIGNED NOT NULL,

    `outcome`     VARCHAR(16)     NOT NULL COMMENT 'confirmed | not_confirmed | unable',
    `case_number` VARCHAR(32)     NULL COMMENT 'What it was confirmed against',
    `detail`      VARCHAR(512)    NULL,

    `confirmed_by` VARCHAR(32)    NOT NULL COMMENT 'Discord id from the session, never from input',
    `officer_id`  BIGINT UNSIGNED NULL,
    `confirmed_at` DATETIME(3)    NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),

    -- One confirmation per hit per query. NULL query ids are exempt, because
    -- MariaDB treats NULLs in a unique key as distinct -- which is exactly the
    -- behaviour wanted here: a hit confirmed from a record page can be
    -- confirmed again on the next encounter, and one raised by a given query is
    -- answered once.
    UNIQUE KEY `uq_fpd_hotfile_confirmations_query` (`query_id`, `hit_type`, `hit_id`),

    -- "Has this flag ever been confirmed, and when", which is what a defence
    -- lawyer asks.
    KEY `idx_fpd_hotfile_confirmations_hit`
        (`agency_id`, `hit_type`, `hit_id`, `confirmed_at`),
    -- "Everything this officer confirmed", which is how the other half of a
    -- misuse investigation runs.
    KEY `idx_fpd_hotfile_confirmations_officer`
        (`agency_id`, `confirmed_by`, `confirmed_at`),
    -- "Every confirmation on this record", for the record's own page.
    KEY `idx_fpd_hotfile_confirmations_record`
        (`agency_id`, `record_type`, `record_id`, `confirmed_at`),

    CONSTRAINT `fk_fpd_hotfile_confirmations_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_hotfile_confirmations_query` FOREIGN KEY (`query_id`)
        REFERENCES `fpd_query_log` (`id`) ON DELETE SET NULL,

    -- Safe from error 1901 (a CHECK over a column a foreign key writes): none
    -- of the four columns below is written by either foreign key above.
    CONSTRAINT `ck_fpd_hotfile_confirmations_hit_type` CHECK (`hit_type` IN
        ('vehicle_flag', 'firearm', 'person_caution')),
    CONSTRAINT `ck_fpd_hotfile_confirmations_record_type` CHECK (`record_type` IN
        ('vehicle', 'firearm', 'person')),
    CONSTRAINT `ck_fpd_hotfile_confirmations_outcome` CHECK (`outcome` IN
        ('confirmed', 'not_confirmed', 'unable')),
    -- A confirmation says what it was confirmed against. "It came back
    -- confirmed" is not an answer to "confirmed against what?", and the route
    -- refuses the same call before it reaches here, so the two agree.
    CONSTRAINT `ck_fpd_hotfile_confirmations_against` CHECK (
        `outcome` <> 'confirmed' OR `case_number` IS NOT NULL OR `detail` IS NOT NULL)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- ============================================================
-- 0007_dispatch.sql
-- ============================================================
-- 0007_dispatch.sql
--
-- Dispatch (CAD): calls, the unit board and AVL, beats, broadcasts and ALPR
-- (spec 7.16, 7.17, 7.18; milestone M4).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
--
-- =============================================================================
-- WHAT A DISPATCH RECORD IS FOR, AND WHY THAT DECIDES THE SHAPE
-- =============================================================================
--
-- Everything else in FredPD is written after the fact by somebody with time to
-- think. A call is written *during* the event, by two people at once, and it is
-- read afterwards to answer three questions that are asked in public:
--
--   * How long did it take us to get there? (received -> dispatched -> en route
--     -> on scene, the five timestamps 7.16 names)
--   * Who was sent, and who had it? (`fpd_call_units`, with the lead unit)
--   * What were we told, and when? (`fpd_call_log`, append-only)
--
-- Two consequences run through every table below.
--
-- **A timestamp is never re-derived and never overwritten.** `dispatched_at` is
-- stamped once, when the call is first assigned, and stays there even if the
-- call is later re-dispatched to a second unit. A response-time report is the
-- arithmetic on these five columns, and a column that moves is a report that
-- changes its answer between two readings of the same call.
--
-- **The status and the timestamps must never disagree.** A call whose status is
-- `on_scene` with `on_scene_at` NULL is not a display bug: it is a call that
-- will be quoted in an inquiry as having had no arrival time. The CHECKs on
-- `fpd_calls` make each of those states impossible to store, rather than
-- something the service layer is trusted to remember on every path -- and the
-- service layer has four paths to `on_scene` (dispatcher, self-assign, the
-- status route, and the export in 11.2).
--
--
-- =============================================================================
-- WHY THERE IS NO POSITION ROUTE, AND WHERE POSITIONS COME FROM
-- =============================================================================
--
-- `fpd_units` holds a last known position (AVL, 7.17) and **no client ever
-- writes it**. The server holds every player's ped and reads
-- `GetEntityCoords` off it, the way `forensics/grid.lua` already does.
--
-- A route that let a client report its own position would be a client telling
-- the server where a police unit is, which is invariant 1 read backwards, and
-- the abuse is not theoretical: the same officer who is being asked why they
-- were not at the call they were dispatched to is the one who would be sending
-- the coordinates that answer it. A false alibi has to be impossible to write,
-- not merely against the rules.
--
-- So there is no position field in any route schema in this milestone, and the
-- columns below are written by the server's own sweep, at the 1-2 second
-- cadence 3.6 sets for sessions with the map open.
--
--
-- =============================================================================
-- THE PENDING QUEUE, WITHOUT A TABLE SCAN PER POLL
-- =============================================================================
--
-- 7.16 wants the pending queue "stacked by priority and age": every open call
-- for the agency, P1 first, oldest first within a priority. Written directly
-- that is
--
--     WHERE agency_id = ? AND status IN ('pending','dispatched','en_route','on_scene')
--     ORDER BY priority, received_at
--
-- and no index makes it cheap. An index on `(agency_id, status, priority,
-- received_at)` gives four separate ranges, one per status, which the optimizer
-- then has to merge and sort -- a filesort over every open call on every poll,
-- growing with the number of calls the server has *ever* taken, because closed
-- calls sit in the same ranges the scan walks past.
--
-- `queue_priority` is the fix and it is the same trick `fpd_record_seals`
-- (0005) uses for live seals: a stored generated column that is the priority
-- while the call is open and NULL once it is closed. Then
--
--     WHERE agency_id = ? AND queue_priority IS NOT NULL
--     ORDER BY queue_priority, received_at
--
-- reads `idx_fpd_calls_queue` forward from the first non-NULL entry and stops
-- when the page is full. No sort, and the cost does not depend on how many
-- calls have been cleared, because every cleared call collapses to one NULL
-- region at the front of the index that a single seek skips. The column is
-- generated rather than maintained by the module for the reason 0005 gives for
-- the phonetic columns: a flag the application sets is a flag some path forgets
-- to clear, and the path that forgets here leaves a cleared call sitting at the
-- top of the queue.
--
--
-- =============================================================================
-- BEAT POLYGONS WITHOUT A GEOMETRY EXTENSION
-- =============================================================================
--
-- 7.17 tags a call with its beat automatically. MariaDB does have spatial types
-- and `ST_Contains`, and this file deliberately does not use them: the point
-- test has to run in `service.lua` (which holds the logic and no natives, so
-- busted can test it), it has to run for a call raised by an export before that
-- call is written, and on a server whose operator has replaced the database
-- with something that answers to MySQL, spatial support is not a promise
-- FredPD can make on their behalf.
--
-- So a polygon is a JSON array of `[x, y]` pairs and the test is an ordinary
-- ray cast in Lua. The `min_x`/`min_y`/`max_x`/`max_y` columns are the bounding
-- box: comparing four doubles rejects almost every beat before the ray cast
-- runs, which is what keeps tagging off the 50 ms route budget (12.1) when an
-- agency has drawn thirty districts.
--
-- The bounding box is the one derived value in this file the database does not
-- compute, because deriving it needs `JSON_TABLE` and that is not allowed in a
-- generated column. It must therefore be written by the same statement that
-- writes the polygon, from one function in `service.lua` that busted tests, and
-- no route may accept one from input: the CHECK below catches an inverted box,
-- but a box that is merely *too small* is valid SQL and silently stops tagging
-- calls in part of a district, which looks like a quiet beat rather than a bug.
--
--
-- =============================================================================
-- WHAT HAPPENS WHEN AN OFFICER IS DELETED
-- =============================================================================
--
-- A roster row can be removed -- somebody leaves the department -- and the
-- question each table below had to answer is whether it is live state or
-- history.
--
--   * `fpd_units` is live state: the board. `ON DELETE CASCADE`, because a unit
--     row for an officer who is no longer on the roster is a ghost on the
--     board, and a ghost with a stale position is worse than an empty row.
--   * `fpd_call_units`, `fpd_call_log` and `fpd_alpr_reads` are history.
--     `ON DELETE SET NULL` on `officer_id`, and each of them also stores the
--     `discord_id` and the `callsign` **as recorded at the time**, which are
--     plain columns no foreign key touches. So "3A-12 was on this call and
--     cleared it Code 4" survives the officer being removed from the roster,
--     exactly as `fpd_firearm_events` keeps `from_party` (0005).
--   * `fpd_calls` itself stores authors as Discord ids (`created_by`,
--     `cleared_by`), never as a foreign key, for the same reason the audit log
--     does: the record of who did something must outlive their roster entry.
--
--
-- =============================================================================
-- MARIADB GOTCHAS: ERROR 1901, AND ITS COUSIN
-- =============================================================================
--
-- **Error 1901** (first met in 0002, `fpd_forensic_index`): a CHECK constraint
-- may not reference a column that a foreign key sets to NULL. Every
-- `ON DELETE SET NULL` in this file therefore points at a column no CHECK
-- mentions -- `fpd_calls.beat_id`, `fpd_call_units.officer_id`,
-- `fpd_call_log.officer_id`, `fpd_units.beat_id`, `fpd_broadcasts.call_id`,
-- `fpd_alpr_reads.officer_id`, `fpd_alpr_reads.hotlist_id` -- and every CHECK
-- here sits on a column no foreign key touches at all. Read that list against
-- the constraints before adding either kind.
--
-- **The same restriction for generated columns.** A foreign key whose action is
-- `SET NULL` or `CASCADE` may not sit on a base column of a stored generated
-- column. That is why `queue_priority` is generated from `status` and
-- `priority`, `active` from `left_at`, `lead_live` from `is_lead` and
-- `left_at`, and `live` from `cancelled_at` -- not one of those base columns is
-- written by a foreign key. The two rules are the same rule wearing different
-- error numbers: the database refuses to let a cascade produce a row it would
-- then have to recompute or reject.
--
-- **`IF NOT EXISTS` everywhere,** because CI applies every migration twice
-- against the same database and the second pass must be a no-op rather than
-- error 1050.
--
--
-- =============================================================================
-- THREE THINGS THIS FILE DELIBERATELY DOES *NOT* DO
-- =============================================================================
--
-- **No `current_call_id` on `fpd_units`.** The board wants "what is this unit
-- on", and a column holding it would be a copy of `fpd_call_units`, with a
-- window in which the two disagree -- the same objection 0005 raises to a
-- materialised hot-file table, and with the same failure mode: a dispatcher
-- looking at a board that says a unit is free while the call it is actually on
-- is still open. `idx_fpd_call_units_unit` makes the live lookup a key seek, so
-- the board is one join rather than one copy.
--
-- **No per-unit arrival timestamps on `fpd_call_units`.** A unit's own en-route
-- and on-scene moments are status changes, and every status change is already
-- a row in `fpd_call_log` with an author and a time. Two places to read "when
-- did 3A-12 arrive" is one place too many when the answer is quoted in court.
--
-- **No `agency_id` filter left to the reader.** Every table here carries
-- `agency_id` and every index starts with it. FredPD is multi-agency: a queue
-- query that forgets the agency does not return an empty list, it returns the
-- sheriff's calls to a city dispatcher, and it does so quietly.
--
-- **Naming note.** Spec 13.2 lists this area as `fpd_call_events`,
-- `fpd_unit_status_log`, `fpd_messages` and `fpd_bulletins`. The names below --
-- `fpd_call_log`, `fpd_broadcasts` -- are the ones M4 is being built against,
-- and they are fewer: a call event is a line in the call log, and a bulletin
-- with an expiry is a broadcast.
--
-- Two of the spec's tables are genuinely absent rather than renamed, and both
-- are worth knowing about before somebody looks for them:
--
--   * **`fpd_unit_status_log` (7.1) is not here.** `fpd_units.status_since`
--     gives the board its time-in-status and gives 7.16 its welfare-check
--     timer, and a status change made *on a call* is a line in that call's log
--     with an author and a time. What is not kept is the history of status
--     changes made off a call -- an activity report over a whole shift. That
--     is a personnel question (7.22, M6) and the table it needs is one a later
--     migration adds; nothing in M4 reads it, and a required table nobody
--     writes to is worse than an honest gap.
--   * **`fpd_premise_hazards` (7.6) is not here.** 7.6 is [S] and unbuilt. The
--     call card shows hazards when that table exists.


-- =============================================================================
-- BEATS AND DISTRICTS (spec 7.17)
-- =============================================================================

-- A beat is a polygon, a precedence and a label. Districts are the same table:
-- a district is a large polygon with a low precedence and a beat is a small one
-- inside it with a higher precedence, so the tagger takes the highest
-- precedence polygon that contains the point and one routine answers both.
--
-- `label_key` is a locale key, never a name (invariant 6), the same choice
-- `fpd_fleet` and `fpd_placements` made -- and for the same reason: a Swedish
-- dispatcher must not read "Downtown" because an English-speaking administrator
-- drew the polygon.
--
-- `polygon` is declared JSON, which on MariaDB is LONGTEXT carrying an
-- automatic `json_valid` constraint; the named CHECK below adds the part that
-- does not give: three vertices, because two points are a line and a line
-- contains nothing. The array is `[[x, y], [x, y], …]` in world coordinates,
-- implicitly closed (the last vertex joins the first). Z is deliberately absent
-- -- a beat is a map area, and an officer in a basement is in the beat above
-- them.
CREATE TABLE IF NOT EXISTS `fpd_beats` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,

    `code`        VARCHAR(32)     NOT NULL COMMENT 'Short operational name: B12, ADAM, NORR',
    `label_key`   VARCHAR(128)    NOT NULL COMMENT 'Locale key, never a literal name (invariant 6)',
    `kind`        VARCHAR(16)     NOT NULL DEFAULT 'beat' COMMENT 'beat | district',

    `polygon`     JSON            NOT NULL COMMENT '[[x,y],…] world coordinates, implicitly closed',
    -- The bounding box of `polygon`, written by the service in the same
    -- statement. A cheap rejection before the ray cast (see the header).
    `min_x`       DOUBLE          NOT NULL,
    `min_y`       DOUBLE          NOT NULL,
    `max_x`       DOUBLE          NOT NULL,
    `max_y`       DOUBLE          NOT NULL,

    -- Highest precedence wins where polygons overlap. A plain integer rather
    -- than a parent link: nesting in a real district map is not a tree, two
    -- districts share a border, and an ordering answers the only question the
    -- tagger asks.
    `precedence`  SMALLINT        NOT NULL DEFAULT 0,
    `enabled`     TINYINT(1)      NOT NULL DEFAULT 1 COMMENT 'Off without deleting, so history keeps its beat',

    `created_by`  VARCHAR(32)     NULL COMMENT 'Discord id',
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_by`  VARCHAR(32)     NULL,
    `updated_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_beats_code` (`agency_id`, `code`),
    -- The tagger's load: every enabled polygon for one agency, ordered by
    -- precedence. It reads `ORDER BY precedence DESC` -- highest precedence is
    -- the most specific polygon, so the first one that contains the point is
    -- the answer -- and an index is read backwards as cheaply as forwards.
    KEY `idx_fpd_beats_active` (`agency_id`, `enabled`, `precedence`),
    CONSTRAINT `fk_fpd_beats_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    -- Safe from 1901: the only foreign key on this table is `agency_id`, which
    -- cascades rather than nulling, and no CHECK here mentions it.
    CONSTRAINT `ck_fpd_beats_kind` CHECK (`kind` IN ('beat', 'district')),
    CONSTRAINT `ck_fpd_beats_polygon` CHECK (
        JSON_VALID(`polygon`) AND JSON_LENGTH(`polygon`) >= 3),
    -- An inverted box matches nothing, so a beat with one would stop tagging
    -- calls and look like a beat nobody patrols.
    CONSTRAINT `ck_fpd_beats_bbox` CHECK (`min_x` <= `max_x` AND `min_y` <= `max_y`),
    CONSTRAINT `ck_fpd_beats_code_value` CHECK (CHAR_LENGTH(TRIM(`code`)) > 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;


-- =============================================================================
-- CALLS (spec 7.16)
-- =============================================================================

-- One row per call.
--
-- `call_number` is allocated from `fpd_counters` under a row lock, like every
-- other number in the suite (13.1, ADR-012), and is never accepted from input
-- (invariant 1) -- including from the `CreateCall` export in 11.2, whose caller
-- is an alarm script with no business naming police record numbers.
--
-- One thing to know before writing that allocation: Appendix D's call format is
-- `{YYMMDD}-{####}`, which is scoped to a *day*, and `fpd_counters.year` is
-- `SMALLINT UNSIGNED`. A raw `YYMMDD` key (260918) does not fit in it and is
-- rejected under strict mode. Either scope the sequence to the year and let the
-- day live only in the printed number, or encode the day in range -- `YY * 400
-- + day_of_year` fits for every year the column can hold. Decide it once in
-- `dispatch/service.lua`, where busted can see it; do not discover it at three
-- in the morning on the first call of a new day.
--
-- `type` and `disposition` are code values rendered through `cad.callType.<x>`
-- and `cad.disposition.<x>` (5.3, invariant 6), and carry no CHECK: the code
-- tables grow, migrations are append-only, and an agency adding a call type
-- must not need a schema change first. The allowlist lives with the module,
-- where an unknown code fails at the call site with its name in the message.
CREATE TABLE IF NOT EXISTS `fpd_calls` (
    `id`             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`      VARCHAR(32)     NOT NULL,
    `call_number`    VARCHAR(32)     NOT NULL COMMENT '260917-0042. Allocated from fpd_counters',

    `type`           VARCHAR(32)     NOT NULL COMMENT 'Code; rendered from cad.callType.<type>',
    `priority`       TINYINT UNSIGNED NOT NULL DEFAULT 3 COMMENT 'P1 life-threatening … P4 report only',
    `status`         VARCHAR(16)     NOT NULL DEFAULT 'pending',

    -- Where. Both halves are nullable and the CHECKs below require at least one
    -- of them: a phone caller who can only give a street name produces a call
    -- with text and no coordinates, and a panic button produces the reverse.
    -- A call with neither is a call nobody can be sent to.
    `x`              DOUBLE          NULL,
    `y`              DOUBLE          NULL,
    `z`              DOUBLE          NULL,
    `location_text`  VARCHAR(191)    NULL COMMENT 'As given: a street, a premise, a cross street',
    `beat_id`        BIGINT UNSIGNED NULL COMMENT 'Tagged automatically from the position (7.17)',

    -- The caller as recorded at the time, which is not the same thing as a
    -- person record: a name given on the phone is often wrong and is evidence
    -- of what was said, not of who it was. The resolved person, when somebody
    -- resolves one, is a `caller` row in `fpd_call_links`.
    `caller_name`    VARCHAR(191)    NULL,
    `caller_phone`   VARCHAR(32)     NULL,

    -- How the call arrived (7.16 intake). `export` is the 11.2 `CreateCall`
    -- path, which has no session behind it -- an alarm script is not an
    -- officer -- which is why `created_by` below is nullable.
    `source`         VARCHAR(16)     NOT NULL DEFAULT 'dispatcher',
    `source_resource` VARCHAR(64)    NULL COMMENT 'Which resource called CreateCall, for the audit trail',

    -- The five timestamps 7.16 names. `received_at` is when the call came in;
    -- the other four are NULL until the call reaches that stage, and are
    -- stamped once and never moved (see the header).
    `received_at`    DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `dispatched_at`  DATETIME(3)     NULL COMMENT 'First unit assigned, self-assignment included',
    `en_route_at`     DATETIME(3)     NULL COMMENT 'First unit en route',
    `on_scene_at`    DATETIME(3)     NULL COMMENT 'First unit on scene',
    `cleared_at`     DATETIME(3)     NULL COMMENT 'Closed, whether cleared or cancelled',

    `disposition`    VARCHAR(32)     NULL COMMENT 'Code; rendered from cad.disposition.<x>',
    `cleared_by`     VARCHAR(32)     NULL COMMENT 'Discord id',

    -- The emergency button (7.16): a P1 call at the officer's position that
    -- "cannot be cleared without supervisor acknowledgement". The
    -- acknowledgement is two columns and a CHECK rather than a habit, because
    -- the habit is broken by the one dispatcher who clears the board at the end
    -- of a shift -- and an unacknowledged panic call is precisely the one that
    -- must still be there in the morning.
    `acknowledged_by` VARCHAR(32)    NULL COMMENT 'Discord id of the supervisor',
    `acknowledged_at` DATETIME(3)    NULL,

    `classification` VARCHAR(16)     NOT NULL DEFAULT 'internal',
    `version`        INT UNSIGNED    NOT NULL DEFAULT 1 COMMENT 'Optimistic lock (13.1) and the delta version (3.6)',
    `created_by`     VARCHAR(32)     NULL COMMENT 'Discord id; NULL for a call raised by an export',
    `created_at`     DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_by`     VARCHAR(32)     NULL,
    `updated_at`     DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    -- The pending queue, in one column. See the header for why this is not an
    -- index over `status`. Base columns `status` and `priority` carry no
    -- foreign key, which is what makes a stored generated column legal here.
    `queue_priority` TINYINT UNSIGNED
        AS (CASE WHEN `status` IN ('cleared', 'cancelled') THEN NULL ELSE `priority` END) STORED,

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_calls_number` (`agency_id`, `call_number`),
    -- The target of the composite foreign keys on the three child tables, so
    -- the database itself guarantees a call's units, log and links cannot drift
    -- into another agency (the shape `fpd_persons` uses in 0005).
    UNIQUE KEY `uq_fpd_calls_id_agency` (`id`, `agency_id`),
    -- The pending queue and the map: open calls, P1 first, oldest first.
    KEY `idx_fpd_calls_queue` (`agency_id`, `queue_priority`, `received_at`),
    -- One status at a time: the closed-call list, and the retention sweep.
    KEY `idx_fpd_calls_status` (`agency_id`, `status`, `received_at`),
    -- Everything today, in order, whatever the status -- the call history page
    -- and the response-time report, neither of which can use the queue index
    -- because both span closed calls.
    KEY `idx_fpd_calls_received` (`agency_id`, `received_at`),
    -- Beat first, not agency first: a beat belongs to exactly one agency, so
    -- this answers "the calls in this district" as well as the agency-first
    -- shape would -- and InnoDB requires an index whose leftmost column is the
    -- foreign key's, or it silently creates an unnamed one of its own. Every
    -- foreign key in this file is covered by an index declared here, the way
    -- `idx_fpd_vehicles_owner` covers its own in 0005.
    KEY `idx_fpd_calls_beat` (`beat_id`, `received_at`),

    CONSTRAINT `fk_fpd_calls_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    -- Single-column and `SET NULL`: a call outlives the beat map being redrawn,
    -- and a composite key would have to null `agency_id` too, which MariaDB
    -- refuses over a NOT NULL column (0005 met the same wall on owner links).
    -- No CHECK below mentions `beat_id` -- that would be error 1901.
    CONSTRAINT `fk_fpd_calls_beat` FOREIGN KEY (`beat_id`)
        REFERENCES `fpd_beats` (`id`) ON DELETE SET NULL,

    CONSTRAINT `ck_fpd_calls_priority` CHECK (`priority` BETWEEN 1 AND 4),
    CONSTRAINT `ck_fpd_calls_status` CHECK (`status` IN
        ('pending', 'dispatched', 'en_route', 'on_scene', 'cleared', 'cancelled')),
    CONSTRAINT `ck_fpd_calls_source` CHECK (`source` IN
        ('dispatcher', 'phone', 'export', 'panic', 'alpr')),
    CONSTRAINT `ck_fpd_calls_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret')),

    -- A position is all three coordinates or none of them. Two thirds of a
    -- position puts a marker on the map at Z = 0, under the map.
    CONSTRAINT `ck_fpd_calls_position` CHECK (
        (`x` IS NULL AND `y` IS NULL AND `z` IS NULL)
        OR (`x` IS NOT NULL AND `y` IS NOT NULL AND `z` IS NOT NULL)),
    -- Somewhere to go: coordinates, or words, or both.
    CONSTRAINT `ck_fpd_calls_where` CHECK (
        `x` IS NOT NULL OR `location_text` IS NOT NULL),

    -- The status and the timestamps agree, one rung at a time.
    --
    -- Deliberately per-status rather than a chain (`on_scene` implies
    -- `dispatched_at`, and so on). The module is expected to stamp
    -- `dispatched_at` on the first assignment however it happened -- a
    -- dispatcher's or the officer's own -- so in practice the chain holds;
    -- but a CHECK that enforces it turns any future flow that skips a rung into
    -- a failed write at the moment an officer presses a key over a body, and
    -- the rung most likely to be skipped is the one nobody thought of. Each
    -- constraint here forbids exactly the state it names and nothing else.
    CONSTRAINT `ck_fpd_calls_dispatched` CHECK (
        `status` <> 'dispatched' OR `dispatched_at` IS NOT NULL),
    CONSTRAINT `ck_fpd_calls_en_route` CHECK (
        `status` <> 'en_route' OR `en_route_at` IS NOT NULL),
    CONSTRAINT `ck_fpd_calls_on_scene` CHECK (
        `status` <> 'on_scene' OR `on_scene_at` IS NOT NULL),
    -- Both terminal statuses close the call, so both stamp `cleared_at`;
    -- only `cleared` carries a disposition, because "cancelled" is the
    -- disposition of a cancelled call and 7.16 asks for a code on the other.
    CONSTRAINT `ck_fpd_calls_closed` CHECK (
        `status` NOT IN ('cleared', 'cancelled') OR `cleared_at` IS NOT NULL),
    CONSTRAINT `ck_fpd_calls_disposition` CHECK (
        `status` <> 'cleared' OR `disposition` IS NOT NULL),
    -- Nothing may be stamped before the call existed. Comparisons against NULL
    -- are unknown rather than false, so these hold for a call that has not
    -- reached the stage yet.
    CONSTRAINT `ck_fpd_calls_order` CHECK (
        (`dispatched_at` IS NULL OR `dispatched_at` >= `received_at`)
        AND (`en_route_at` IS NULL OR `en_route_at` >= `received_at`)
        AND (`on_scene_at` IS NULL OR `on_scene_at` >= `received_at`)
        AND (`cleared_at` IS NULL OR `cleared_at` >= `received_at`)),
    -- 7.16: an emergency call cannot be cleared without supervisor
    -- acknowledgement. Cancelling one is closed off for the same reason --
    -- otherwise the way to clear an unacknowledged panic call is to cancel it.
    CONSTRAINT `ck_fpd_calls_panic_ack` CHECK (
        `source` <> 'panic'
        OR `status` NOT IN ('cleared', 'cancelled')
        OR `acknowledged_at` IS NOT NULL)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;


-- Which units are on a call, who has the lead, and when they joined and left
-- (7.16).
--
-- A row per assignment rather than per unit, because a unit can be assigned,
-- cleared to something more urgent, and assigned back -- and the response-time
-- question is about the assignment, not about the unit. `left_at` closes a row;
-- nothing is deleted.
--
-- The two generated columns are the `fpd_record_seals` trick from 0005 applied
-- twice over. `active` is 1 while the assignment is open and NULL once it is
-- closed, so the unique key below means "a unit is on a call once at a time"
-- while any number of closed assignments coexist (NULLs are distinct in a
-- MariaDB unique index). `lead_live` does the same for the lead unit: at most
-- one live lead per call, enforced by the database rather than by a
-- check-then-insert in Lua that two dispatchers can interleave. A call with two
-- lead units is a call where nobody is in charge and both think the other is.
--
-- `discord_id` and `callsign` are recorded here as they were at the time, so a
-- deleted roster row (`officer_id` nulled) still leaves a readable unit list --
-- and so the live-assignment unique key keeps working, since it is keyed on
-- `discord_id` rather than on the nullable `officer_id`.
CREATE TABLE IF NOT EXISTS `fpd_call_units` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `call_id`     BIGINT UNSIGNED NOT NULL,

    `officer_id`  BIGINT UNSIGNED NULL COMMENT 'Nulled if the roster row goes; see discord_id',
    `discord_id`  VARCHAR(32)     NOT NULL COMMENT 'From the session, never from input',
    `callsign`    VARCHAR(32)     NULL COMMENT 'As it was at assignment',

    `is_lead`     TINYINT(1)      NOT NULL DEFAULT 0,
    `joined_at`   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `left_at`     DATETIME(3)     NULL COMMENT 'NULL while the unit is on the call',
    `assigned_by` VARCHAR(32)     NULL COMMENT 'Discord id; equal to discord_id on a self-assign',

    `active`      TINYINT UNSIGNED AS (CASE WHEN `left_at` IS NULL THEN 1 ELSE NULL END) STORED,
    `lead_live`   TINYINT UNSIGNED
        AS (CASE WHEN `left_at` IS NULL AND `is_lead` = 1 THEN 1 ELSE NULL END) STORED,

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_call_units_live` (`call_id`, `discord_id`, `active`),
    UNIQUE KEY `uq_fpd_call_units_lead` (`call_id`, `lead_live`),
    -- "Who is on this call", which is the card, in join order. `agency_id`
    -- sits in the middle so this index also covers the composite foreign key
    -- below (leftmost `call_id`, `agency_id`); every read carries the agency
    -- anyway, so the ordering is unaffected.
    KEY `idx_fpd_call_units_call` (`call_id`, `agency_id`, `joined_at`),
    -- "What is this unit on", which is the board -- and the reason `fpd_units`
    -- needs no `current_call_id` copy (see the header).
    KEY `idx_fpd_call_units_unit` (`agency_id`, `discord_id`, `active`),
    KEY `idx_fpd_call_units_officer` (`officer_id`),

    CONSTRAINT `fk_fpd_call_units_call` FOREIGN KEY (`call_id`, `agency_id`)
        REFERENCES `fpd_calls` (`id`, `agency_id`) ON DELETE CASCADE,
    -- Single-column `SET NULL` for the reason given on `fpd_calls.beat_id`, and
    -- `officer_id` is mentioned by no CHECK here (error 1901) and by no
    -- generated column (its cousin, see the header).
    CONSTRAINT `fk_fpd_call_units_officer` FOREIGN KEY (`officer_id`)
        REFERENCES `fpd_officers` (`id`) ON DELETE SET NULL,
    CONSTRAINT `ck_fpd_call_units_left` CHECK (
        `left_at` IS NULL OR `left_at` >= `joined_at`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;


-- The narrative log (7.16): every note and every status change, append-only,
-- with an author.
--
-- Nothing in the application updates or deletes a row here. It is the record of
-- what was known and when, which is the half of a call that is read back in an
-- inquiry, and a narrative that can be edited afterwards is worth nothing in
-- one.
--
-- **Invariant 6 is enforced by the schema, not by discipline.** A log has two
-- kinds of line: what a person typed, which is content, and what the system
-- recorded, which is user-facing text. `body` holds the first. `message_key`
-- plus `message_args` hold the second -- `cad.log.dispatched` with
-- `{"callsign": "3A-12"}` -- and the NUI renders it in the reader's language.
-- The CHECK makes the wrong one impossible to store: a generated line with an
-- English sentence in `body` would be a Swedish dispatcher reading English, and
-- the i18n checker cannot see a sentence that reaches the database.
--
-- The author is nullable on purpose. A call raised by the `CreateCall` export
-- (11.2) has no officer behind it, and its first log line is written before any
-- session exists; a NOT NULL author would mean an alarm script could not open a
-- call at all.
CREATE TABLE IF NOT EXISTS `fpd_call_log` (
    `id`           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`    VARCHAR(32)     NOT NULL,
    `call_id`      BIGINT UNSIGNED NOT NULL,

    `entry_type`   VARCHAR(16)     NOT NULL
                                   COMMENT 'The event that happened; the list is ck_fpd_call_log_type below',
    `body`         VARCHAR(2048)   NULL COMMENT 'What a person typed. Content, not UI text',
    `message_key`  VARCHAR(128)    NULL COMMENT 'Locale key for a generated line (invariant 6)',
    `message_args` JSON            NULL COMMENT 'Placeholder values for message_key',

    `officer_id`   BIGINT UNSIGNED NULL COMMENT 'Nulled if the roster row goes; see discord_id',
    `discord_id`   VARCHAR(32)     NULL COMMENT 'From the session; NULL for a system line',
    `callsign`     VARCHAR(32)     NULL COMMENT 'As it was when the line was written',
    `created_at`   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    -- The call card, in order. Keyset pagination on `id` for a long call
    -- (12.2), and `agency_id` in the middle so this covers the composite
    -- foreign key too.
    KEY `idx_fpd_call_log_call` (`call_id`, `agency_id`, `id`),
    -- "Everything this officer wrote", the other half of a misuse enquiry.
    KEY `idx_fpd_call_log_author` (`agency_id`, `discord_id`, `created_at`),

    CONSTRAINT `fk_fpd_call_log_call` FOREIGN KEY (`call_id`, `agency_id`)
        REFERENCES `fpd_calls` (`id`, `agency_id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_call_log_officer` FOREIGN KEY (`officer_id`)
        REFERENCES `fpd_officers` (`id`) ON DELETE SET NULL,
    -- Safe from 1901: neither foreign key writes `entry_type`, `body` or
    -- `message_key`.
    CONSTRAINT `ck_fpd_call_log_type` CHECK (`entry_type` IN
        ('created', 'note', 'dispatched', 'unit_joined', 'unit_left',
         'lead_changed', 'unit_status', 'call_status', 'linked', 'unlinked',
         'cleared')),
    CONSTRAINT `ck_fpd_call_log_content` CHECK (
        (`entry_type` = 'note' AND `body` IS NOT NULL)
        OR (`entry_type` <> 'note' AND `message_key` IS NOT NULL))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;


-- Persons and vehicles linked to a call (7.16).
--
-- **Polymorphic, with no foreign key to the record,** which is the same shape
-- `fpd_record_compartments` (0005) and `fpd_hotfile_confirmations` (0006) use,
-- and it is chosen here for a reason those two do not have: the alternative --
-- a nullable `person_id` and a nullable `vehicle_id`, each with `ON DELETE SET
-- NULL` -- cannot be constrained. A CHECK that exactly one of them is populated
-- is error 1901 twice over, so the one rule that matters ("a link points at
-- something") would be unenforceable, and the unique key that stops a
-- dispatcher linking the same suspect four times would be keyed on nullable
-- columns and therefore not unique at all.
--
-- The cost is that an expunged person leaves a link row pointing at nothing.
-- That is the safe direction -- an orphan link grants nobody anything, and the
-- retention sweep takes it -- and `label` keeps the plate or the name as it was
-- read out over the radio, which is what the call is read back for anyway.
--
-- The repo must therefore check that the target belongs to the session's agency
-- before writing, because without a foreign key the database cannot -- and a
-- link is one of the few places a client supplies a record id at all.
CREATE TABLE IF NOT EXISTS `fpd_call_links` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `call_id`     BIGINT UNSIGNED NOT NULL,

    `target_type` VARCHAR(16)     NOT NULL COMMENT 'person | vehicle',
    `target_id`   BIGINT UNSIGNED NOT NULL COMMENT 'fpd_persons.id or fpd_vehicles.id',
    `role`        VARCHAR(24)     NOT NULL DEFAULT 'involved',
    `label`       VARCHAR(191)    NULL COMMENT 'Name or plate as recorded, so the row survives the record',
    `detail`      VARCHAR(512)    NULL,

    `created_by`  VARCHAR(32)     NULL COMMENT 'Discord id',
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    -- One link per record per call. Changing the role updates the row rather
    -- than stacking a second one nobody would think to remove -- the same
    -- upsert `fpd_record_grants` relies on in 0005.
    UNIQUE KEY `uq_fpd_call_links_target` (`call_id`, `target_type`, `target_id`),
    -- "Every call this person has been on", which is the record page and the
    -- reason the link is worth storing at all.
    KEY `idx_fpd_call_links_record` (`agency_id`, `target_type`, `target_id`, `created_at`),
    -- Covers the composite foreign key below; the unique key above starts with
    -- `call_id` but not with `call_id, agency_id`, so without this InnoDB
    -- creates an unnamed index of its own.
    KEY `idx_fpd_call_links_call` (`call_id`, `agency_id`),

    CONSTRAINT `fk_fpd_call_links_call` FOREIGN KEY (`call_id`, `agency_id`)
        REFERENCES `fpd_calls` (`id`, `agency_id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_call_links_target` CHECK (`target_type` IN ('person', 'vehicle')),
    CONSTRAINT `ck_fpd_call_links_role` CHECK (`role` IN
        ('caller', 'victim', 'suspect', 'witness', 'involved'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;


-- =============================================================================
-- THE UNIT BOARD AND AVL (spec 7.1, 7.16, 7.17)
-- =============================================================================

-- One row per officer signed on, keyed by `officer_id`.
--
-- **Per officer, not per session.** A session is a connection: it ends when the
-- server restarts, when the player's game crashes, and every time they change
-- character. A unit is a person on duty, and it has to survive all three --
-- an officer who reconnects mid-call must come back as the same unit, on the
-- same call, with the same time-in-status, or the board reports them as having
-- gone available at the moment their game crashed.
--
-- The cost of persisting it is ghosts: rows left behind by a restart. The
-- module must clear those at boot by setting every unit of the agency
-- `off_duty`, because after a restart there is no session to contradict the
-- row. That sweep writes a status nobody asked for, which is the right
-- direction to be wrong in: a board that has forgotten a real unit is corrected
-- by that unit pressing one key, and a board still showing a unit who left two
-- hours ago sends somebody to a call nobody is going to.
--
-- **Callsign is deliberately not unique.** A two-officer car signs on under one
-- callsign (7.1 partners), so uniqueness would forbid partners; the board
-- groups by callsign instead.
--
-- The position columns are the AVL (7.17) and no client writes them. See the
-- header.
CREATE TABLE IF NOT EXISTS `fpd_units` (
    `officer_id`    BIGINT UNSIGNED NOT NULL,
    `agency_id`     VARCHAR(32)     NOT NULL,
    `discord_id`    VARCHAR(32)     NOT NULL COMMENT 'From the session, never from input',

    `callsign`      VARCHAR(32)     NOT NULL,
    `status`        VARCHAR(16)     NOT NULL DEFAULT 'available',
    -- When the status last changed -- the board's "time in status" column, and
    -- what the welfare-check timer reads (7.16: a unit on scene too long).
    -- The module stamps this on a status change and on nothing else. It is
    -- deliberately not `ON UPDATE CURRENT_TIMESTAMP(3)`: the AVL sweep writes
    -- this row every second or two, and an automatic stamp would reset the
    -- timer on every sweep -- so the welfare check would never fire, and it
    -- would never fire for the unit that has stopped moving.
    `status_since`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    `beat_id`       BIGINT UNSIGNED NULL COMMENT 'Assignment (7.1), not where they are',
    `division`      VARCHAR(32)     NULL,
    `vehicle_plate` VARCHAR(16)     NULL COMMENT 'Auto-detected agency vehicle (7.1)',
    `vehicle_model` VARCHAR(64)     NULL,

    -- Last known position, read server-side off the ped (invariant 1, D1).
    -- NULL until the first sweep sees them, and left as it was when they
    -- disconnect: "last known" is the honest name for it.
    `x`             DOUBLE          NULL,
    `y`             DOUBLE          NULL,
    `z`             DOUBLE          NULL,
    `heading`       FLOAT           NULL COMMENT 'Which way the marker points',
    `position_at`   DATETIME(3)     NULL COMMENT 'When the position was read; stale is not the same as unknown',

    `signed_on_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_at`    DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`officer_id`),
    -- The board: every unit for the agency, grouped by status, oldest in status
    -- first -- which is also the welfare-check query (status, status_since).
    KEY `idx_fpd_units_board` (`agency_id`, `status`, `status_since`),
    KEY `idx_fpd_units_callsign` (`agency_id`, `callsign`),
    -- Sign-on, and the AVL sweep resolving a connected player to their unit.
    KEY `idx_fpd_units_discord` (`discord_id`),
    -- Beat first, so it covers the foreign key as well as "who is working this
    -- beat" (a beat belongs to one agency, so nothing is lost).
    KEY `idx_fpd_units_beat` (`beat_id`),

    -- CASCADE, not SET NULL: this is live state, and a unit row for an officer
    -- who is no longer on the roster is a ghost on the board (see the header).
    CONSTRAINT `fk_fpd_units_officer` FOREIGN KEY (`officer_id`)
        REFERENCES `fpd_officers` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_units_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_units_beat` FOREIGN KEY (`beat_id`)
        REFERENCES `fpd_beats` (`id`) ON DELETE SET NULL,
    -- Appendix E, plus `off_duty` for a row kept across a sign-off. Safe from
    -- 1901: no foreign key writes `status`, `callsign` or the coordinates.
    CONSTRAINT `ck_fpd_units_status` CHECK (`status` IN
        ('off_duty', 'available', 'en_route', 'on_scene', 'busy',
         'transporting', 'at_station', 'out_of_service', 'emergency')),
    CONSTRAINT `ck_fpd_units_callsign` CHECK (CHAR_LENGTH(TRIM(`callsign`)) > 0),
    -- All three coordinates or none: a half-read position puts a unit under the
    -- map, and the recommendation routine would then offer it as the closest.
    CONSTRAINT `ck_fpd_units_position` CHECK (
        (`x` IS NULL AND `y` IS NULL AND `z` IS NULL)
        OR (`x` IS NOT NULL AND `y` IS NOT NULL AND `z` IS NOT NULL))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;


-- =============================================================================
-- BROADCASTS (spec 7.16, 7.26)
-- =============================================================================

-- BOLOs and all-units messages, with an expiry.
--
-- `title` and `body` are content an officer wrote, not UI text, so they are
-- stored as typed -- the same distinction `fpd_call_log` draws between `body`
-- and `message_key`.
--
-- An expired broadcast is not deleted and a cancelled one is stamped, never
-- removed: "what was out on the air at the time" is a question asked after an
-- arrest, and the answer has to survive the shift it was asked about.
--
-- Not to be confused with the enforcement BOLO of spec 7.13 -- a record with a
-- subject, a case and a lifecycle, which is M2 and which no migration has
-- built yet; what exists today is the vehicle flag `fpd_vehicle_flags.kind =
-- 'bolo'` (0005). A broadcast is the *message*:
-- it may carry a BOLO, a road closure or a briefing note, and it expires on its
-- own without anything happening to the record behind it.
CREATE TABLE IF NOT EXISTS `fpd_broadcasts` (
    `id`           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`    VARCHAR(32)     NOT NULL,

    `kind`         VARCHAR(24)     NOT NULL DEFAULT 'all_units'
                                   COMMENT 'Widest member is attempt_to_locate, 17 chars',
    `priority`     TINYINT UNSIGNED NOT NULL DEFAULT 3 COMMENT 'Same 1-4 scale as a call',
    `title`        VARCHAR(191)    NOT NULL,
    `body`         VARCHAR(2048)   NOT NULL,
    -- The plate a lookout is for. Content, like `title` and `body`: it is
    -- what a unit matches an ALPR read against by eye, and it is not a
    -- hotlist entry -- a banner is `fpd_hotlist`, under its own permission
    -- (7.18). No index: the board is read whole through the live index, and
    -- one here would cost every insert to serve a lookup nothing performs.
    `plate`        VARCHAR(16)     NULL COMMENT 'Upper-cased and trimmed on write',
    `call_id`      BIGINT UNSIGNED NULL COMMENT 'The call it came out of, when there was one',

    `expires_at`   DATETIME(3)     NULL COMMENT 'NULL runs until it is cancelled',
    `cancelled_at` DATETIME(3)     NULL,
    `cancelled_by` VARCHAR(32)     NULL COMMENT 'Discord id',
    `created_by`   VARCHAR(32)     NULL COMMENT 'Discord id; NULL for a system broadcast',
    `created_at`   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    -- What is out right now: live, unexpired, newest first. The same live-flag
    -- index shape `fpd_vehicle_flags` uses in 0005 -- two equalities and a
    -- range, because expiry is a time and cannot be a generated flag.
    KEY `idx_fpd_broadcasts_live` (`agency_id`, `cancelled_at`, `expires_at`),
    KEY `idx_fpd_broadcasts_history` (`agency_id`, `created_at`),
    KEY `idx_fpd_broadcasts_call` (`call_id`),

    CONSTRAINT `fk_fpd_broadcasts_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    -- `SET NULL`, so the retention sweep over old calls cannot take a standing
    -- BOLO off the air with them. No CHECK below mentions `call_id` (1901).
    CONSTRAINT `fk_fpd_broadcasts_call` FOREIGN KEY (`call_id`)
        REFERENCES `fpd_calls` (`id`) ON DELETE SET NULL,
    CONSTRAINT `ck_fpd_broadcasts_kind` CHECK (`kind` IN
        ('bolo', 'all_units', 'attempt_to_locate', 'information')),
    CONSTRAINT `ck_fpd_broadcasts_priority` CHECK (`priority` BETWEEN 1 AND 4),
    CONSTRAINT `ck_fpd_broadcasts_body` CHECK (CHAR_LENGTH(TRIM(`body`)) > 0),
    CONSTRAINT `ck_fpd_broadcasts_plate` CHECK (
        `plate` IS NULL OR CHAR_LENGTH(TRIM(`plate`)) > 0),
    -- An expiry before the broadcast was written is a message that was never on
    -- the air, which is a typed date, not an intention.
    CONSTRAINT `ck_fpd_broadcasts_expiry` CHECK (
        `expires_at` IS NULL OR `expires_at` > `created_at`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;


-- =============================================================================
-- ALPR (spec 7.18)
-- =============================================================================

-- The plate hotlist: plates worth a banner, and why.
--
-- **This is not a cache of the hot files, and nothing may sync one into it.**
-- 0005 is explicit that a hit is *derived* at query time from the record that
-- is the truth for it -- `fpd_vehicle_flags` for a stolen car, a warrant for a
-- wanted person -- because a copy has a window in which it disagrees with the
-- record, and the window is discovered by the officer the stale hit points a
-- gun at. That reasoning has not changed, and an ALPR read runs the same
-- derived check every query runs.
--
-- This table is the layer underneath it: plate-level entries that no record can
-- produce. A plate seen leaving a scene with no vehicle record behind it; a
-- plate an investigator wants flagged for a week without a flag on the
-- registration; a surveillance target whose hit must not raise a banner at all.
-- Every row here is its own truth, written by a person who can be named, with
-- an expiry.
--
-- `silent` is the surveillance case (7.18, and section 9): the read is logged
-- and the hit is recorded, and the unit is told nothing. A banner would tell a
-- corrupt officer they are being watched, and the officer is sometimes the
-- subject.
CREATE TABLE IF NOT EXISTS `fpd_hotlist` (
    `id`           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`    VARCHAR(32)     NOT NULL,

    `plate`        VARCHAR(16)     NOT NULL COMMENT 'Upper-cased and trimmed on write',
    `reason`       VARCHAR(16)     NOT NULL COMMENT 'Why it is on the list',
    `detail`       VARCHAR(512)    NULL,
    `case_number`  VARCHAR(32)     NULL,
    `silent`       TINYINT(1)      NOT NULL DEFAULT 0 COMMENT 'Log the hit, show the unit nothing',

    `expires_at`   DATETIME(3)     NULL COMMENT 'NULL stands until it is cancelled',
    `cancelled_at` DATETIME(3)     NULL,
    `cancelled_by` VARCHAR(32)     NULL COMMENT 'Discord id',
    `created_by`   VARCHAR(32)     NULL COMMENT 'Discord id',
    `created_at`   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    `live`         TINYINT UNSIGNED AS (CASE WHEN `cancelled_at` IS NULL THEN 1 ELSE NULL END) STORED,

    PRIMARY KEY (`id`),
    -- One live entry per plate per reason. Adding a plate that is already
    -- listed for the same reason extends the existing row through
    -- `ON DUPLICATE KEY UPDATE` -- including re-arming one whose `expires_at`
    -- has passed -- rather than stacking a second row that raises two banners
    -- and that nobody would think to cancel twice. Cancelled rows drop out of
    -- the key, because NULLs are distinct in a MariaDB unique index.
    UNIQUE KEY `uq_fpd_hotlist_live` (`agency_id`, `plate`, `reason`, `live`),
    -- The check every read makes: this agency, this plate, still live, not
    -- expired. The unique key's `(agency_id, plate)` prefix would find the
    -- rows; this one also carries `live` and the expiry, so the check discards
    -- nothing after reading and never touches the table for a plate that is
    -- not listed -- which is almost every plate a patrol car drives past.
    KEY `idx_fpd_hotlist_check` (`agency_id`, `plate`, `live`, `expires_at`),
    KEY `idx_fpd_hotlist_manage` (`agency_id`, `cancelled_at`, `created_at`),

    CONSTRAINT `fk_fpd_hotlist_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    -- Safe from 1901 and from its generated-column cousin: the only foreign key
    -- here is `agency_id`, which cascades, and `live` is generated from
    -- `cancelled_at`, which no foreign key writes.
    CONSTRAINT `ck_fpd_hotlist_reason` CHECK (`reason` IN
        ('stolen_vehicle', 'wanted_person', 'warrant', 'bolo',
         'investigation', 'other')),
    CONSTRAINT `ck_fpd_hotlist_plate` CHECK (CHAR_LENGTH(TRIM(`plate`)) > 0),
    CONSTRAINT `ck_fpd_hotlist_expiry` CHECK (
        `expires_at` IS NULL OR `expires_at` > `created_at`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;


-- Plate reads: time, place and unit (7.18).
--
-- The highest-volume table in the suite by an order of magnitude -- one row per
-- plate a patrol car drives past -- so it is deliberately narrow: no
-- `classification`, no `version`, no `updated_at`, and no foreign key to the
-- vehicle register. Resolving a plate to a registration is done at read time
-- against `fpd_vehicles`; storing the resolved id would add a second index to
-- maintain on every insert and would be wrong the moment the plate changes
-- hands, which `fpd_vehicle_plates` (0005) exists to record.
--
-- Retention is 30 days by default (7.18, 13.3) and the sweep deletes by
-- `(agency_id, read_at)`, which `idx_fpd_alpr_reads_time` serves. This is the
-- one table in FredPD whose rows are meant to be deleted on a schedule: a
-- permanent record of every car every patrol has driven past is a movement
-- database, and 11.4 is why it does not become one.
--
-- `hit` and `hotlist_id` record what the read matched *at the time*, which is
-- not the same as what the hotlist says now, and that is the point: "was this
-- car flagged when the camera saw it" is the question a stop is justified by.
CREATE TABLE IF NOT EXISTS `fpd_alpr_reads` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,

    `plate`       VARCHAR(16)     NOT NULL COMMENT 'Upper-cased and trimmed on write',
    `read_at`     DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `x`           DOUBLE          NOT NULL COMMENT 'Where the read happened, from the server (invariant 1)',
    `y`           DOUBLE          NOT NULL,
    `z`           DOUBLE          NOT NULL,

    `officer_id`  BIGINT UNSIGNED NULL COMMENT 'Nulled if the roster row goes; see discord_id',
    `discord_id`  VARCHAR(32)     NULL COMMENT 'NULL for a fixed camera with no unit behind it',
    `callsign`    VARCHAR(32)     NULL COMMENT 'As it was at the time of the read',
    `camera`      VARCHAR(16)     NULL COMMENT 'front | rear | fixed',

    `hit`         TINYINT(1)      NOT NULL DEFAULT 0 COMMENT 'Matched the hotlist when it was read',
    `hotlist_id`  BIGINT UNSIGNED NULL COMMENT 'Which entry matched, while that entry exists',

    PRIMARY KEY (`id`),
    -- "Where has this plate been", which is the whole reason to keep reads.
    KEY `idx_fpd_alpr_reads_plate` (`agency_id`, `plate`, `read_at`),
    -- The recent-reads list, and the retention sweep (13.3).
    KEY `idx_fpd_alpr_reads_time` (`agency_id`, `read_at`),
    -- Hits only, which is the review screen and a far smaller set.
    KEY `idx_fpd_alpr_reads_hit` (`agency_id`, `hit`, `read_at`),
    -- Both of these cover a foreign key. `hotlist_id` also answers "every read
    -- this hotlist entry matched", which is how an entry is reviewed before it
    -- is extended.
    KEY `idx_fpd_alpr_reads_officer` (`officer_id`),
    KEY `idx_fpd_alpr_reads_hotlist` (`hotlist_id`, `read_at`),

    CONSTRAINT `fk_fpd_alpr_reads_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_alpr_reads_officer` FOREIGN KEY (`officer_id`)
        REFERENCES `fpd_officers` (`id`) ON DELETE SET NULL,
    -- The read outlives the hotlist entry that matched it -- cancelling a
    -- hotlist entry must not erase the evidence that a stop was justified when
    -- it was made. No CHECK mentions `hotlist_id` or `officer_id` (1901).
    CONSTRAINT `fk_fpd_alpr_reads_hotlist` FOREIGN KEY (`hotlist_id`)
        REFERENCES `fpd_hotlist` (`id`) ON DELETE SET NULL,
    CONSTRAINT `ck_fpd_alpr_reads_plate` CHECK (CHAR_LENGTH(TRIM(`plate`)) > 0),
    CONSTRAINT `ck_fpd_alpr_reads_camera` CHECK (
        `camera` IS NULL OR `camera` IN ('front', 'rear', 'fixed'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- The counter a call number is allocated from (Appendix D, ADR-012)
-- -----------------------------------------------------------------------------

-- `fpd_counters.year` is the sequence's SCOPE, not a year. 0005 declared it
-- SMALLINT UNSIGNED because every sequence then in existence was year-scoped or
-- unscoped. A call number restarts daily -- Appendix D gives `{YYMMDD}-{####}`
-- -- so its scope value is the day key 260918, which does not fit in 65535 and
-- is rejected outright under strict mode. The first call of the day would fail
-- to allocate a number, which is the first thing a dispatcher does.
--
-- MODIFY rather than a new column: the meaning is unchanged for every existing
-- row (0 unscoped, YYYY year-scoped) and only the range grows. Idempotent, so
-- CI's second pass over this file is a no-op. 0005 has shipped and is not
-- edited (invariant 8).
ALTER TABLE `fpd_counters`
    MODIFY COLUMN `year` MEDIUMINT UNSIGNED NOT NULL DEFAULT 0
    COMMENT 'Scope key: 0 = never restarts, YYYY = year-scoped, YYMMDD = day-scoped (calls)';

-- ============================================================
-- 0008_brott.sql
-- ============================================================
-- 0008_brott.sql
--
-- Brottskatalogen: the offence catalogue every record downstream picks from
-- (spec 7.10; milestone M2).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
--
-- =============================================================================
-- WHY THIS IS NOT THE PENAL CODE TABLE SPEC 7.10 ORIGINALLY DESCRIBED
-- =============================================================================
--
-- 7.10 was written against a US penal code: a class (felony, misdemeanor,
-- infraction), a fine, a jail time, licence points. Swedish criminal law has
-- none of those four as a per-offence constant, and a table shaped that way
-- would have to be filled with invented numbers before the first offence could
-- be stored.
--
-- What brottsbalken has instead is a **straffskala** -- a span. Stöld is
-- "fängelse i högst två år"; ringa stöld is "böter eller fängelse i högst sex
-- månader"; grov stöld is "fängelse i lägst sex månader och högst sex år". So
-- the penalty of an offence is three facts, not one: whether böter is available
-- at all, the floor in months, and the ceiling in months. Those are the columns
-- below, and they are what `Brott.straffskala` in the service reads.
--
-- There is no `class` column, because the Swedish equivalent is not a property
-- of the offence -- it is the **grad** of this particular instance of it, and
-- brottsbalken writes each grad as its own numbered stycke with its own span.
-- Ringa stöld and grov stöld are therefore two rows, not one row with a
-- modifier, which is also how a prosecutor cites them.
--
--
-- =============================================================================
-- VERSIONING: "A CHANGE NEVER ALTERS PAST RECORDS" (7.10)
-- =============================================================================
--
-- An anmälan written in 2026 must still read, in 2029, as the offence that was
-- on the books when it was written -- both the wording and the span. A server
-- operator who edits a straffskala must not silently rewrite the legal basis of
-- every closed case that cites it.
--
-- So a row is immutable once records point at it, and an edit **inserts a new
-- version** rather than updating in place. The identity of an offence is
-- `(agency_id, code, version)`; `code` alone is the offence across time, and
-- `superseded_at` marks which versions are no longer current.
--
-- A record therefore stores both halves. `Brott.citation` builds the string an
-- officer reads, and `fpd_brott_versions` is deliberately not a separate table:
-- one table with a version column keeps a single foreign-key target, so an
-- anmälan's offence row can point at exactly the version it was written under
-- with one constraint rather than two.
--
-- `uq_fpd_brott_current` is a partial index in spirit and a full one in fact:
-- MariaDB has no partial unique index, so currency is enforced by the generated
-- column `current_marker`, which is the code for a live row and NULL for a
-- superseded one. NULLs do not collide in a unique index, so any number of
-- superseded versions of an offence may exist while at most one is current.
-- This is the same trick 0005 used for a person's primary photo.
--
--
-- =============================================================================
-- WHY THE LABELS ARE KEYS AND NOT TEXT
-- =============================================================================
--
-- Invariant 6, and 5.3 for code tables specifically: a label is a locale key,
-- never a literal string. That holds here even though Swedish is the primary
-- vocabulary of this module rather than a translation of it -- `pnpm i18n:check`
-- can see a missing key and cannot see a missing sentence that reached the
-- database. The keys are `brott.<code>.rubrik` and `brott.<code>.beskrivning`,
-- and the seed file adds both to `en.json` and `sv.json` for every offence it
-- inserts.

-- -----------------------------------------------------------------------------
-- Brottskatalogen
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_brott` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,

    `code`        VARCHAR(32)     NOT NULL COMMENT 'Stable across versions, e.g. BrB-8-1',
    `version`     SMALLINT UNSIGNED NOT NULL DEFAULT 1,

    -- Where it sits in the statute. Both nullable: specialstraffrätt
    -- (narkotikastrafflagen, trafikbrottslagen) is not in brottsbalken and has
    -- no kapitel, and a citation there is carried by `code` alone.
    `balk`        VARCHAR(16)     NULL COMMENT 'BrB, NSL, TBL — NULL for an agency-local code',
    `kapitel`     TINYINT UNSIGNED NULL,
    `paragraf`    TINYINT UNSIGNED NULL,
    `stycke`      TINYINT UNSIGNED NULL COMMENT 'Which stycke carries this grad',

    `label_key`   VARCHAR(128)    NOT NULL COMMENT 'Locale key, never a literal rubrik (invariant 6)',
    `description_key` VARCHAR(128) NULL,

    `grad`        VARCHAR(24)     NOT NULL DEFAULT 'normal',

    -- The straffskala. Months throughout, so the sentencing arithmetic never
    -- mixes units; `boter` is a separate boolean because "böter eller fängelse
    -- i högst sex månader" and "fängelse i högst sex månader" are different
    -- spans with the same ceiling.
    `boter`       TINYINT(1)      NOT NULL DEFAULT 0 COMMENT 'Böter available for this grad',
    `fangelse_min_months` SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    `fangelse_max_months` SMALLINT UNSIGNED NULL COMMENT 'NULL means livstid',

    -- Preparation, attempt and conspiracy are punishable only where the statute
    -- says so (BrB 23), and a charging screen that offers "försök till" on an
    -- offence where it does not exist invites a charge that cannot be filed.
    `forsok`      TINYINT(1)      NOT NULL DEFAULT 0,
    `forberedelse` TINYINT(1)     NOT NULL DEFAULT 0,

    -- Preskription (BrB 35:1) follows from the ceiling, but not by a formula
    -- simple enough to derive in SQL, and several offences have a statutory
    -- exception. Stored, so the value an investigator sees is the one the
    -- catalogue author checked.
    `preskription_years` SMALLINT UNSIGNED NULL COMMENT 'NULL = no preskription (BrB 35:2)',

    -- Currency. `superseded_at` is the fact; `current_marker` exists only so the
    -- unique index below can enforce one live version per code. Generated, so
    -- the two can never disagree.
    `superseded_at` DATETIME(3)   NULL,
    `current_marker` VARCHAR(32)
        GENERATED ALWAYS AS (IF(`superseded_at` IS NULL, `code`, NULL)) STORED,

    `created_by`  VARCHAR(32)     NULL COMMENT 'Discord id of the admin who added this version',
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_brott_version` (`agency_id`, `code`, `version`),
    UNIQUE KEY `uq_fpd_brott_current` (`agency_id`, `current_marker`),
    UNIQUE KEY `uq_fpd_brott_id_agency` (`id`, `agency_id`),
    KEY `idx_fpd_brott_kapitel` (`agency_id`, `balk`, `kapitel`, `paragraf`),
    CONSTRAINT `fk_fpd_brott_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_brott_code` CHECK (CHAR_LENGTH(TRIM(`code`)) > 0),
    CONSTRAINT `ck_fpd_brott_grad` CHECK (`grad` IN
        ('ringa', 'normal', 'grov', 'synnerligen_grov')),
    -- A span whose floor is above its ceiling is not a straffskala. Checked
    -- here rather than in the service alone, because the catalogue is editable
    -- by an administrator and a reversed span would silently make every
    -- sentence calculation on that offence nonsense.
    CONSTRAINT `ck_fpd_brott_span` CHECK (
        `fangelse_max_months` IS NULL
        OR `fangelse_min_months` <= `fangelse_max_months`),
    -- Böter and a floor above zero are mutually exclusive: if the statute sets
    -- a fängelse minimum, böter is not on the table for that grad.
    CONSTRAINT `ck_fpd_brott_boter` CHECK (
        `boter` = 0 OR `fangelse_min_months` = 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- What a record cites
-- -----------------------------------------------------------------------------

-- Not a table of its own yet. The anmälan migration (0009) carries
-- `fpd_anmalan_brott`, because the row that links an offence to a record also
-- carries the role it plays in *that* record -- how many counts, against which
-- person, whether it is a försök -- and none of that belongs to the catalogue.
--
-- What matters here is the shape of the reference every such table will use:
-- `(brott_id)` alone, pointing at one immutable version row, with
-- `uq_fpd_brott_id_agency` available for the composite foreign key that keeps a
-- record from citing another agency's catalogue.

-- ============================================================
-- 0009_anmalan.sql
-- ============================================================
-- 0009_anmalan.sql
--
-- Anmälan och förundersökning: the offence report and the investigation it
-- opens (spec 7.7, 7.8; milestone M2).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
--
-- =============================================================================
-- WHY THIS IS NOT THE INCIDENT REPORT SPEC 7.7 ORIGINALLY DESCRIBED
-- =============================================================================
--
-- 7.7 was written against a US RMS: NIBRS sections, a report that a supervisor
-- approves, and a case that an investigator owns. The procedure decision
-- (section 19) settled on Swedish procedure, and the shape that follows from it
-- differs in one structural way rather than in vocabulary.
--
-- **There are two records, not one, and they have different owners.**
--
--   * An **anmälan** is a report of an offence. An officer writes it, a
--     supervisor approves it, and once approved it is locked -- the workflow
--     7.7 describes, with Swedish names.
--   * A **förundersökning** is the investigation. It is *opened by a decision*
--     (beslut att inleda FU), it is led by a **förundersökningsledare** who is
--     either a police FU-ledare or an **åklagare**, and it ends with a decision
--     too: nedläggning, or slutdelgivning and redovisning to the prosecutor.
--
-- One anmälan may open one FU; one FU may collect many anmälningar. The
-- approval workflow belongs to the first and the legal lifecycle to the second,
-- and merging them -- which a single "report with a status" would do -- would
-- mean a supervisor's approval and a prosecutor's decision to drop a case being
-- the same column.
--
--
-- =============================================================================
-- WHY THE FÖRUNDERSÖKNING IS NOT fpd_intel_cases
-- =============================================================================
--
-- The intelligence module already has a case (`fpd_intel_cases`, migration
-- 0001, ported from PD-Span). It is not this, and the two are deliberately kept
-- apart:
--
--   * An intel case links `fpd_intel_persons` and `fpd_intel_orgs` -- the
--     intelligence register's own soft records, which exist precisely because
--     intelligence is held about people who have no master record.
--     A förundersökning links `fpd_persons`, the master name index, because a
--     misstänkt in a real investigation is a real identified person.
--   * An intel case has no legal status. An FU has nothing else: who decided to
--     open it, who leads it, and on what ground it ended are the whole record.
--
-- So `fpd_forundersokning.intel_case_id` links one to the other for the case
-- where intelligence work became an investigation, and neither table tries to
-- be both. Section 10 keeps PD-Span's case as the intelligence one; 7.8's is
-- this.
--
--
-- =============================================================================
-- LOCKING, VERSIONS AND WHAT "APPROVED" MEANS
-- =============================================================================
--
-- 7.7: "Approved reports are locked. After approval, changes only through a
-- supplemental report or a supervisor-approved amendment. Every version is
-- kept."
--
-- Enforced in the schema rather than trusted to the service, because there are
-- four write paths to an anmälan and only one of them is the obvious one:
--
--   * `ck_fpd_anmalan_locked` makes the `godkand` status imply an approver and
--     an approval timestamp, so an approved anmälan with nobody's name on it
--     cannot be stored.
--   * `fpd_anmalan_versions` holds a snapshot per transition, written by the
--     same transaction that moves the status. A version table the service is
--     trusted to write to is a version table with gaps in it exactly where
--     somebody took a shortcut.
--   * A **tilläggsuppgift** is an ordinary row with `parent_id` set, so it gets
--     its own number, its own author and its own approval. It is not an edit of
--     its parent, and nothing in the schema lets it become one.
--
-- The narrative is **editor JSON** (invariant 10), stored as JSON and validated
-- as such by `ck_fpd_anmalan_handelseforlopp`. Raw HTML is never stored and
-- never rendered.
--
--
-- =============================================================================
-- THE COUNTER
-- =============================================================================
--
-- An anmälan takes a number from `fpd_counters` under the `report` kind, in the
-- format Appendix D gives: `{AGENCY}-{YY}-{######}`. An FU takes one under
-- `case`: `{AGENCY}-C{YY}-{#####}`. Both are year-scoped. The kinds already
-- exist in `server/core/counters.lua`; no ALTER is needed here.
--
-- Unique over `(agency_id, number)` rather than over the number alone, which
-- is what Appendix D's note about load-bearing agencies allows: both formats
-- carry the agency already, and the composite key is what lets two agencies
-- run independent sequences without a shared lock.

-- -----------------------------------------------------------------------------
-- Förundersökningen
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_forundersokning` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `number`      VARCHAR(32)     NOT NULL COMMENT '{AGENCY}-C{YY}-{#####} (Appendix D)',

    `title`       VARCHAR(191)    NOT NULL,
    `status`      VARCHAR(24)     NOT NULL DEFAULT 'inledd',

    -- Who leads it, and in what capacity. The capacity is not cosmetic: BrB and
    -- RB give the åklagare powers a police FU-ledare does not have, and the
    -- tvångsmedel module (0010) reads this column to decide whether a decision
    -- may be taken at all.
    `fu_ledare`   VARCHAR(32)     NULL COMMENT 'Discord id of the förundersökningsledare',
    `ledare_kind` VARCHAR(16)     NOT NULL DEFAULT 'polis',

    -- Where intelligence work became an investigation (see the header).
    `intel_case_id` BIGINT UNSIGNED NULL,

    `opened_by`   VARCHAR(32)     NULL COMMENT 'Who decided to inleda FU',
    `opened_at`   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    -- How it ended. `closed_reason` is a locale key, never a sentence
    -- (invariant 6); the free text beside it is the FU-ledare's own note.
    `closed_by`   VARCHAR(32)     NULL,
    `closed_at`   DATETIME(3)     NULL,
    `closed_reason` VARCHAR(128)  NULL COMMENT 'Locale key: brott kan ej styrkas, spaningsuppslag saknas, …',
    `closed_note` TEXT            NULL,

    `classification` VARCHAR(16)  NOT NULL DEFAULT 'internal',
    `version`     INT UNSIGNED    NOT NULL DEFAULT 1,
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_fu_number` (`agency_id`, `number`),
    UNIQUE KEY `uq_fpd_fu_id_agency` (`id`, `agency_id`),
    KEY `idx_fpd_fu_status` (`agency_id`, `status`),
    KEY `idx_fpd_fu_ledare` (`agency_id`, `fu_ledare`),
    CONSTRAINT `fk_fpd_fu_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_fu_intel_case` FOREIGN KEY (`intel_case_id`)
        REFERENCES `fpd_intel_cases` (`id`) ON DELETE SET NULL,
    CONSTRAINT `ck_fpd_fu_status` CHECK (`status` IN
        ('inledd', 'slutdelgiven', 'redovisad', 'nedlagd')),
    CONSTRAINT `ck_fpd_fu_ledare_kind` CHECK (`ledare_kind` IN ('polis', 'aklagare')),
    CONSTRAINT `ck_fpd_fu_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret')),
    -- An FU that has ended must say who ended it and when. The two closing
    -- statuses are the ones a prosecutor quotes, and a nedläggning with nobody's
    -- name on it is the one nobody can be asked about afterwards.
    CONSTRAINT `ck_fpd_fu_closed` CHECK (
        (`status` NOT IN ('nedlagd', 'redovisad'))
        OR (`closed_by` IS NOT NULL AND `closed_at` IS NOT NULL)),
    CONSTRAINT `ck_fpd_fu_number` CHECK (CHAR_LENGTH(TRIM(`number`)) > 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Anmälan
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_anmalan` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `number`      VARCHAR(32)     NOT NULL COMMENT '{AGENCY}-{YY}-{######} (Appendix D)',

    -- A tilläggsuppgift (7.7's supplemental) is a row with a parent. It gets
    -- its own number, author and approval; it is never an edit of its parent.
    `parent_id`   BIGINT UNSIGNED NULL,
    `fu_id`       BIGINT UNSIGNED NULL,

    -- Pre-fill from a händelse (7.16). Kept as a link rather than copied, so
    -- the call's own timestamps stay the authority on when things happened.
    `call_id`     BIGINT UNSIGNED NULL,

    `title`       VARCHAR(191)    NOT NULL,
    `status`      VARCHAR(16)     NOT NULL DEFAULT 'utkast',

    -- Händelseförlopp: editor JSON, never HTML (invariant 10).
    `handelseforlopp` JSON        NULL,

    `occurred_at` DATETIME(3)     NULL COMMENT 'When the offence happened, not when it was reported',
    `occurred_place` VARCHAR(191) NULL,

    `created_by`  VARCHAR(32)     NOT NULL COMMENT 'Discord id of the author',
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    -- The three transitions, each with the person who made it. `returned_note`
    -- is the supervisor's reason, which the author has to be able to read.
    `submitted_by` VARCHAR(32)    NULL,
    `submitted_at` DATETIME(3)    NULL,
    `returned_by`  VARCHAR(32)    NULL,
    `returned_at`  DATETIME(3)    NULL,
    `returned_note` TEXT          NULL,
    `approved_by`  VARCHAR(32)    NULL,
    `approved_at`  DATETIME(3)    NULL,

    `classification` VARCHAR(16)  NOT NULL DEFAULT 'internal',
    `version`     INT UNSIGNED    NOT NULL DEFAULT 1,
    `updated_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_anmalan_number` (`agency_id`, `number`),
    UNIQUE KEY `uq_fpd_anmalan_id_agency` (`id`, `agency_id`),
    KEY `idx_fpd_anmalan_status` (`agency_id`, `status`),
    KEY `idx_fpd_anmalan_author` (`agency_id`, `created_by`, `status`),
    KEY `idx_fpd_anmalan_fu` (`fu_id`),
    KEY `idx_fpd_anmalan_parent` (`parent_id`),
    CONSTRAINT `fk_fpd_anmalan_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    -- RESTRICT rather than CASCADE: deleting an anmälan that has
    -- tilläggsuppgifter hanging off it would take approved, locked records with
    -- it. Nothing in the module deletes one anyway -- there is no delete route
    -- -- and this is the backstop for the path that does not exist yet.
    CONSTRAINT `fk_fpd_anmalan_parent` FOREIGN KEY (`parent_id`)
        REFERENCES `fpd_anmalan` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_fpd_anmalan_fu` FOREIGN KEY (`fu_id`)
        REFERENCES `fpd_forundersokning` (`id`) ON DELETE SET NULL,
    CONSTRAINT `fk_fpd_anmalan_call` FOREIGN KEY (`call_id`)
        REFERENCES `fpd_calls` (`id`) ON DELETE SET NULL,
    CONSTRAINT `ck_fpd_anmalan_status` CHECK (`status` IN
        ('utkast', 'inlamnad', 'atersand', 'godkand')),
    CONSTRAINT `ck_fpd_anmalan_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret')),
    -- 7.7's locking rule, in the schema. An approved anmälan carries its
    -- approver and the moment of approval, or it is not storable.
    CONSTRAINT `ck_fpd_anmalan_locked` CHECK (
        (`status` <> 'godkand')
        OR (`approved_by` IS NOT NULL AND `approved_at` IS NOT NULL)),
    -- Likewise for the two intermediate states, so a status and its timestamps
    -- can never disagree -- the same reasoning `fpd_calls` uses in 0007.
    CONSTRAINT `ck_fpd_anmalan_submitted` CHECK (
        (`status` NOT IN ('inlamnad', 'godkand'))
        OR (`submitted_by` IS NOT NULL AND `submitted_at` IS NOT NULL)),
    CONSTRAINT `ck_fpd_anmalan_returned` CHECK (
        (`status` <> 'atersand')
        OR (`returned_by` IS NOT NULL AND `returned_at` IS NOT NULL)),
    -- A tilläggsuppgift cannot be its own parent, and cannot close a longer
    -- cycle either. **Neither is enforced here**, and not for want of trying:
    -- MariaDB refuses `CHECK (parent_id <> id)` outright -- "Function or
    -- expression 'AUTO_INCREMENT' cannot be used in the CHECK clause of `id`"
    -- -- and a deeper cycle is not expressible in a CHECK at all.
    --
    -- So the rule lives in `Anmalan.parentIsAllowed`, which walks the chain,
    -- and this note is here so the next reader of the constraint list does not
    -- conclude it was forgotten. What the schema does hold is the other half:
    -- `uq_fpd_anmalan_id_agency` is what a parent reference is checked against,
    -- so a tilläggsuppgift can never hang off another agency's anmälan.
    CONSTRAINT `ck_fpd_anmalan_handelseforlopp` CHECK (
        `handelseforlopp` IS NULL OR JSON_VALID(`handelseforlopp`)),
    CONSTRAINT `ck_fpd_anmalan_number` CHECK (CHAR_LENGTH(TRIM(`number`)) > 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- The charges on an anmälan
-- -----------------------------------------------------------------------------

-- One row per **count**, not per offence. Three counts of grov stöld is three
-- rows, because that is what BrB 26:2 computes over (see 0008 and
-- `Brott.parseIds`) and because each count may name a different misstänkt.
--
-- `brott_id` points at one immutable catalogue *version* (0008), so the legal
-- basis of a charge is fixed at the moment it was written and stays readable
-- after the catalogue moves on. That is 7.10's versioning rule arriving here,
-- and it is why the foreign key is to the version row rather than to a code.

CREATE TABLE IF NOT EXISTS `fpd_anmalan_brott` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `anmalan_id`  BIGINT UNSIGNED NOT NULL,
    `brott_id`    BIGINT UNSIGNED NOT NULL COMMENT 'One catalogue version (0008)',

    -- Who this count is against. Nullable: an anmälan is very often written
    -- with no suspect at all, which is the ordinary case rather than an
    -- incomplete record.
    `person_id`   BIGINT UNSIGNED NULL,

    -- BrB 23. A charge may be for the attempt or the preparation rather than
    -- the completed offence, and the catalogue row says whether that is even
    -- available (`forsok`, `forberedelse`).
    `stage`       VARCHAR(16)     NOT NULL DEFAULT 'fullbordat',

    `note`        VARCHAR(255)    NULL,
    `created_by`  VARCHAR(32)     NULL,
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    KEY `idx_fpd_anmalan_brott_anmalan` (`anmalan_id`),
    KEY `idx_fpd_anmalan_brott_person` (`person_id`),
    KEY `idx_fpd_anmalan_brott_brott` (`brott_id`),
    CONSTRAINT `fk_fpd_anmalan_brott_anmalan` FOREIGN KEY (`anmalan_id`)
        REFERENCES `fpd_anmalan` (`id`) ON DELETE CASCADE,
    -- RESTRICT: a catalogue version a charge cites must not be removable. 0008
    -- has no delete path for exactly this reason; this is the backstop.
    CONSTRAINT `fk_fpd_anmalan_brott_brott` FOREIGN KEY (`brott_id`)
        REFERENCES `fpd_brott` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_fpd_anmalan_brott_person` FOREIGN KEY (`person_id`)
        REFERENCES `fpd_persons` (`id`) ON DELETE SET NULL,
    CONSTRAINT `ck_fpd_anmalan_brott_stage` CHECK (`stage` IN
        ('fullbordat', 'forsok', 'forberedelse', 'stampling'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- The people on an anmälan
-- -----------------------------------------------------------------------------

-- The Swedish roles, which are not a translation of the US ones. `målsägande`
-- is the injured party and carries rights a "victim" does not have in a US
-- report -- the right to be heard, and to bring a claim alongside the
-- prosecution -- so it is a role with legal consequence rather than a label.

CREATE TABLE IF NOT EXISTS `fpd_anmalan_personer` (
    `anmalan_id`  BIGINT UNSIGNED NOT NULL,
    `person_id`   BIGINT UNSIGNED NOT NULL,
    `roll`        VARCHAR(24)     NOT NULL,

    `note`        VARCHAR(255)    NULL,
    `created_by`  VARCHAR(32)     NULL,
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    -- One person may hold two roles on one anmälan -- an anmälare who is also
    -- the målsägande is the commonest report there is -- so the key carries the
    -- role.
    PRIMARY KEY (`anmalan_id`, `person_id`, `roll`),
    KEY `idx_fpd_anmalan_personer_person` (`person_id`),
    CONSTRAINT `fk_fpd_anmalan_personer_anmalan` FOREIGN KEY (`anmalan_id`)
        REFERENCES `fpd_anmalan` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_anmalan_personer_person` FOREIGN KEY (`person_id`)
        REFERENCES `fpd_persons` (`id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_anmalan_personer_roll` CHECK (`roll` IN
        ('misstankt', 'malsagande', 'vittne', 'anmalare', 'annan'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Every version is kept (7.7)
-- -----------------------------------------------------------------------------

-- A snapshot per transition, written by the transaction that moves the status.
-- Append-only in the same sense the audit log is (invariant 11): there is no
-- update path and no delete path anywhere in the module.
--
-- `snapshot` is the whole anmälan as it read at that moment, JSON, including
-- its charges and its people. Denormalised on purpose: the point of a version
-- is to answer "what did this say when it was approved", and a version that
-- pointed at live rows would answer with what those rows say now.

CREATE TABLE IF NOT EXISTS `fpd_anmalan_versions` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `anmalan_id`  BIGINT UNSIGNED NOT NULL,
    `version`     INT UNSIGNED    NOT NULL,

    `status`      VARCHAR(16)     NOT NULL COMMENT 'The status this version was written at',
    `snapshot`    JSON            NOT NULL,

    -- The electronic signature 7.7 asks for: who, and when. The name and badge
    -- number are inside the snapshot, taken from the roster at the moment of
    -- signing, so a later rank change does not rewrite a signature.
    `signed_by`   VARCHAR(32)     NULL,
    `signed_at`   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_anmalan_versions` (`anmalan_id`, `version`),
    CONSTRAINT `fk_fpd_anmalan_versions_anmalan` FOREIGN KEY (`anmalan_id`)
        REFERENCES `fpd_anmalan` (`id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_anmalan_versions_snapshot` CHECK (JSON_VALID(`snapshot`)),
    CONSTRAINT `ck_fpd_anmalan_versions_status` CHECK (`status` IN
        ('utkast', 'inlamnad', 'atersand', 'godkand'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- ============================================================
-- 0010_frihetsberovande.sql
-- ============================================================
-- 0010_frihetsberovande.sql
--
-- Frihetsberövande: gripande, anhållande, häktning (spec 7.9; milestone M2).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
--
-- =============================================================================
-- WHY THIS IS A CHAIN AND NOT AN ARREST RECORD
-- =============================================================================
--
-- 7.9 was written against a US arrest: one record, one arresting officer, one
-- rights advisement, one booking. Swedish procedure deprives somebody of their
-- liberty in three separate decisions, taken by three different people, each
-- with its own ground and its own clock:
--
--   1. **Gripande** (RB 24:7) -- a police officer may seize somebody who is
--      anhållen i sin frånvaro, or who is caught in the act of an offence that
--      can carry fängelse. The officer decides, and it is provisional.
--   2. **Anhållande** (RB 24:6) -- the **åklagare** decides whether the
--      frihetsberövande continues. If they do not, the gripne is released.
--   3. **Häktning** (RB 24:13) -- the **tingsrätt** decides, at a hearing, on
--      the prosecutor's häktningsframställan.
--
-- One row per chain rather than one per stage, because the chain is the thing:
-- every clock below is measured between two of its columns, and a query that
-- had to join three tables to ask "how long has this person been held" would be
-- run on a screen an officer is watching a countdown on.
--
-- The stage columns are therefore nullable and filled in order, and `status` is
-- a summary of which of them are set. `ck_fpd_frihet_chain` is what makes them
-- agree: a row cannot claim to be `anhallen` with no anhållandebeslut on it.
--
--
-- =============================================================================
-- THE CLOCKS, AND WHY THEY ARE STORED RATHER THAN DERIVED
-- =============================================================================
--
-- Two statutory deadlines run from these columns:
--
--   * **RB 24:12** -- a häktningsframställan must reach the court *senast
--     klockan tolv tredje dagen efter anhållningsbeslutet*. Not seventy-two
--     hours: a wall-clock noon, three days after the decision, which is a
--     different instant depending on what time of day the anhållande happened.
--   * **RB 24:13** -- the häktningsförhandling must be held without delay and
--     at the latest four days after the gripande (or the anhållande, where
--     there was no gripande).
--
-- `Frihet.deadlines` computes both, and this table stores neither. That is
-- deliberate: a stored deadline is a second copy of a rule that changes when
-- the rule does, and a row written under the old arithmetic would keep quoting
-- it. What is stored is the three moments the rules are computed *from*, each
-- written once and never updated -- the same reasoning `fpd_calls` uses for its
-- five timestamps in 0007.
--
-- The timestamps are DATETIME(3) and the server stores UTC (spec 5.2). The noon
-- in RB 24:12 is a *local* noon, so the conversion happens in the service,
-- where the timezone convar is readable and busted can drive it.
--
--
-- =============================================================================
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT CARRY
-- =============================================================================
--
-- **Inskrivning i arrest** (booking): the mugshot, the ten-print capture and the
-- property inventory of 7.9's second half. That is M6 and needs the booking
-- terminal, the camera and an ox_inventory stash per booking. A frihetsberövande
-- row will link to it when it exists; nothing here presumes its shape.
--
-- **Häktningsframställan as a document.** The column below records that one was
-- made and when, because that is what the clock needs. The document itself is
-- court work.

-- -----------------------------------------------------------------------------
-- The chain
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_frihetsberovande` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `number`      VARCHAR(32)     NOT NULL COMMENT 'Counter kind `arrest` (Appendix D)',

    `person_id`   BIGINT UNSIGNED NOT NULL,
    `fu_id`       BIGINT UNSIGNED NULL,
    `anmalan_id`  BIGINT UNSIGNED NULL,

    `status`      VARCHAR(16)     NOT NULL DEFAULT 'gripen',

    -- 1. Gripande (RB 24:7). The officer's own decision.
    --
    -- `gripen_at` is the instant the whole chain is measured from and is
    -- written once. Not `ON UPDATE CURRENT_TIMESTAMP`: a four-day deadline
    -- whose start moves every time the row is touched is a deadline that is
    -- never missed and never met.
    `gripen_at`   DATETIME(3)     NULL,
    `gripen_by`   VARCHAR(32)     NULL COMMENT 'Discord id of the officer',
    `gripande_grund` VARCHAR(128) NULL COMMENT 'Locale key, never a sentence (invariant 6)',
    `gripande_plats` VARCHAR(191) NULL,

    -- Underrättelse om misstanke (RB 24:9): the gripne must be told what they
    -- are suspected of and why they are being held. Recorded as a moment
    -- because the question asked afterwards is *when*, not whether.
    `underrattad_at` DATETIME(3)  NULL,

    -- 2. Anhållande (RB 24:6). The prosecutor's decision, and the column that
    --    starts the RB 24:12 clock.
    `anhallen_at` DATETIME(3)     NULL,
    `anhallen_by` VARCHAR(32)     NULL COMMENT 'Discord id of the åklagare',
    `anhallande_grund` VARCHAR(128) NULL COMMENT 'Locale key',

    -- 3. Häktningsframställan (RB 24:12), and the hearing it leads to.
    `framstallan_at` DATETIME(3)  NULL,
    `framstallan_by` VARCHAR(32)  NULL,

    -- 4. Häktning (RB 24:13). The court's decision.
    `haktad_at`   DATETIME(3)     NULL,
    `haktad_by`   VARCHAR(32)     NULL COMMENT 'Discord id of the domare',
    `haktning_beslut` VARCHAR(16) NULL COMMENT 'haktad | frigiven — what the court decided',

    -- Release, from whichever stage it happened at.
    `frigiven_at` DATETIME(3)     NULL,
    `frigiven_by` VARCHAR(32)     NULL,
    `frigiven_grund` VARCHAR(128) NULL COMMENT 'Locale key',

    `classification` VARCHAR(16)  NOT NULL DEFAULT 'internal',
    `version`     INT UNSIGNED    NOT NULL DEFAULT 1,
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_frihet_number` (`agency_id`, `number`),
    UNIQUE KEY `uq_fpd_frihet_id_agency` (`id`, `agency_id`),
    KEY `idx_fpd_frihet_person` (`person_id`),
    KEY `idx_fpd_frihet_fu` (`fu_id`),
    -- The index the countdown screen reads: everybody this agency is currently
    -- holding, which is a short list off a narrow index rather than a scan of
    -- every frihetsberövande the server has ever recorded.
    KEY `idx_fpd_frihet_open` (`agency_id`, `status`, `gripen_at`),
    CONSTRAINT `fk_fpd_frihet_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_frihet_person` FOREIGN KEY (`person_id`)
        REFERENCES `fpd_persons` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_fpd_frihet_fu` FOREIGN KEY (`fu_id`)
        REFERENCES `fpd_forundersokning` (`id`) ON DELETE SET NULL,
    CONSTRAINT `fk_fpd_frihet_anmalan` FOREIGN KEY (`anmalan_id`)
        REFERENCES `fpd_anmalan` (`id`) ON DELETE SET NULL,
    CONSTRAINT `ck_fpd_frihet_status` CHECK (`status` IN
        ('gripen', 'anhallen', 'framstalld', 'haktad', 'frigiven')),
    CONSTRAINT `ck_fpd_frihet_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret')),
    CONSTRAINT `ck_fpd_frihet_beslut` CHECK (
        `haktning_beslut` IS NULL OR `haktning_beslut` IN ('haktad', 'frigiven')),

    -- The chain, in the schema.
    --
    -- Each stage requires the one before it, and each requires its own
    -- decision-maker. Without this a row could claim somebody was häktad
    -- without ever having been anhållen, which is not a data error -- it is a
    -- record of a detention that had no legal basis, and it would be read as
    -- one.
    CONSTRAINT `ck_fpd_frihet_chain` CHECK (
        (`status` <> 'gripen'     OR (`gripen_at` IS NOT NULL AND `gripen_by` IS NOT NULL))
        AND (`status` <> 'anhallen'   OR (`anhallen_at` IS NOT NULL AND `anhallen_by` IS NOT NULL))
        AND (`status` <> 'framstalld' OR (`anhallen_at` IS NOT NULL AND `framstallan_at` IS NOT NULL))
        AND (`status` <> 'haktad'     OR (`anhallen_at` IS NOT NULL AND `haktad_at` IS NOT NULL
                                          AND `haktad_by` IS NOT NULL))
        AND (`status` <> 'frigiven'   OR (`frigiven_at` IS NOT NULL AND `frigiven_by` IS NOT NULL))),

    -- Anhållande cannot precede the gripande it followed. Both are written by
    -- the server from its own clock, so this can only fail on a row somebody
    -- constructed by hand -- which is exactly when it is worth catching.
    CONSTRAINT `ck_fpd_frihet_order` CHECK (
        `gripen_at` IS NULL OR `anhallen_at` IS NULL OR `anhallen_at` >= `gripen_at`),

    CONSTRAINT `ck_fpd_frihet_number` CHECK (CHAR_LENGTH(TRIM(`number`)) > 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- What somebody is held for
-- -----------------------------------------------------------------------------

-- The offences a frihetsberövande rests on, one row per count, pointing at an
-- immutable catalogue version the same way `fpd_anmalan_brott` does.
--
-- A separate list from the anmälan's on purpose. They are usually the same
-- offences and they are not the same statement: an anmälan records what is
-- reported to have happened, and this records what a person is being deprived
-- of their liberty for. The second is the one a court reads back, and it
-- narrows -- a prosecutor anhåller for two of the five offences the anmälan
-- lists, and the chain has to say which two.

CREATE TABLE IF NOT EXISTS `fpd_frihet_brott` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `frihet_id`   BIGINT UNSIGNED NOT NULL,
    `brott_id`    BIGINT UNSIGNED NOT NULL COMMENT 'One catalogue version (0008)',
    `stage`       VARCHAR(16)     NOT NULL DEFAULT 'fullbordat',

    `created_by`  VARCHAR(32)     NULL,
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    KEY `idx_fpd_frihet_brott_frihet` (`frihet_id`),
    KEY `idx_fpd_frihet_brott_brott` (`brott_id`),
    CONSTRAINT `fk_fpd_frihet_brott_frihet` FOREIGN KEY (`frihet_id`)
        REFERENCES `fpd_frihetsberovande` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_frihet_brott_brott` FOREIGN KEY (`brott_id`)
        REFERENCES `fpd_brott` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `ck_fpd_frihet_brott_stage` CHECK (`stage` IN
        ('fullbordat', 'forsok', 'forberedelse', 'stampling'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- The log
-- -----------------------------------------------------------------------------

-- Append-only, like `fpd_call_log` in 0007 and for the same reason: the
-- question asked about a detention afterwards is always "what happened, and
-- when", and a row that could be edited answers it with what somebody would
-- prefer to have happened.
--
-- This is where förhör, the defence lawyer's arrival, meals and the calls a
-- detainee is entitled to are recorded. `kind` is a locale key rather than an
-- enum, because the list is a matter of what a department logs rather than of
-- what the law names, and a CHECK here would have to be ALTERed by a migration
-- before a server could record something its own routines require.

CREATE TABLE IF NOT EXISTS `fpd_frihet_log` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `frihet_id`   BIGINT UNSIGNED NOT NULL,

    `kind`        VARCHAR(64)     NOT NULL COMMENT 'Locale key: forhor, forsvarare, maltid, …',
    `note`        VARCHAR(500)    NULL COMMENT 'Free text: one officer writing about this detention',
    `logged_by`   VARCHAR(32)     NULL,
    `logged_at`   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    KEY `idx_fpd_frihet_log_frihet` (`frihet_id`, `logged_at`),
    CONSTRAINT `fk_fpd_frihet_log_frihet` FOREIGN KEY (`frihet_id`)
        REFERENCES `fpd_frihetsberovande` (`id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_frihet_log_kind` CHECK (CHAR_LENGTH(TRIM(`kind`)) > 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- ============================================================
-- 0011_tvangsmedel.sql
-- ============================================================
-- 0011_tvangsmedel.sql
--
-- Tvångsmedel och efterlysning: coercive measures and wanted persons
-- (spec 7.12, 7.13; milestone M2).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
--
-- =============================================================================
-- WHY THERE IS NO JUDGE IN THIS FILE
-- =============================================================================
--
-- 7.12 was written around a US warrant: an officer applies, a **judge** reviews
-- and signs, and the warrant is then served. Swedish procedure puts almost all
-- of that somewhere else.
--
-- **Husrannsakan** (RB 28:1) and **kroppsvisitation** (RB 28:11) are decided by
-- the **förundersökningsledare** -- a police FU-ledare for the ordinary case,
-- an **åklagare** for the rest. A court decides only where RB says so, which in
-- practice means häktning (0010) and the secret measures of M5. So the
-- decision-maker column here is a *capacity*, and `ck_fpd_tvang_decider`
-- deliberately allows all three: a rule that forced every husrannsakan through
-- a judge would stop the commonest coercive measure in the suite on a server
-- with nobody playing one.
--
-- **The arrest warrant has no Swedish equivalent at all.** What FredPD needs it
-- for -- making somebody turn up as wanted on a query -- is an **efterlysning**,
-- and the specific case behind most of them is *anhållen i sin frånvaro*: the
-- prosecutor has decided to anhålla somebody who is not present. That is a
-- decision recorded in 0010's chain, and an efterlysning is the consequence of
-- it rather than a different kind of warrant. The two are linked, and either
-- can exist without the other.
--
--
-- =============================================================================
-- WHAT A VALID MEASURE MEANS, AND WHY THE EXPORT DEPENDS ON IT
-- =============================================================================
--
-- Spec 14 promises `HasSearchWarrant(targetType, targetId)` to raid and door
-- scripts, so `ox_doorlock` can refuse to open a door that nothing authorises.
-- That export is the reason this table has a validity *window* rather than a
-- boolean:
--
--   * `valid_from` and `valid_until` bound it in time. A decision with no end
--     is a standing authority to enter somebody's home, which is not a thing RB
--     grants.
--   * `upphavd_at` is the revocation. Set, and the measure stops being valid
--     immediately, whatever its window said.
--   * `verkstalld_at` records execution. A measure that has been carried out
--     does **not** stop being valid: RB allows a husrannsakan to be resumed,
--     and a door script that refused the second entry because the first was
--     logged would be enforcing a rule nobody wrote.
--
-- `idx_fpd_tvang_valid` is what the export reads, and it is ordered to answer
-- the only question that matters at a door: is there a live measure for this
-- target, right now.
--
--
-- =============================================================================
-- EFTERLYSNING AND THE HOT-FILE CHECK
-- =============================================================================
--
-- 7.2's hot-file check already runs on every query, and `modules/query` reads
-- it. An efterlysning is one of its sources, so the table carries the two
-- columns that check needs and nothing decorative: who, and why. The banner
-- text is a locale key.
--
-- Deliberately **per person and not per citizenid**: an efterlysning names a
-- record in the master index (`fpd_persons`), because that is what a query
-- resolves to and what an officer confirms a hit against. `IsWanted(citizenid)`
-- in spec 14 resolves the citizenid to a person first.

-- -----------------------------------------------------------------------------
-- Tvångsmedel
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_tvangsmedel` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `number`      VARCHAR(32)     NOT NULL COMMENT 'Counter kind `warrant` (Appendix D)',

    `kind`        VARCHAR(32)     NOT NULL,

    -- What it is directed at. `target_kind` says which register `target_id`
    -- points into, the same shape `fpd_call_links` uses in 0007 -- a real
    -- foreign key is impossible when the target may be one of three tables, so
    -- the pair is validated by the service and by the CHECK below.
    `target_kind` VARCHAR(16)     NOT NULL,
    `target_id`   BIGINT UNSIGNED NOT NULL,
    `target_label` VARCHAR(191)   NULL COMMENT 'The address or name as recorded, so the row survives the record',

    `fu_id`       BIGINT UNSIGNED NULL,

    -- Who decided, and in what capacity. RB gives most of these to the
    -- förundersökningsledare; the capacity is what makes the row auditable.
    `decided_by`  VARCHAR(32)     NOT NULL,
    `decider_kind` VARCHAR(16)    NOT NULL DEFAULT 'fu_ledare',
    `grund`       VARCHAR(128)    NOT NULL COMMENT 'Locale key, never a sentence (invariant 6)',
    `scope`       VARCHAR(500)    NULL COMMENT 'What may be searched for and seized — free text, written by the decider',

    `valid_from`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `valid_until` DATETIME(3)     NOT NULL,

    -- Execution. Recorded, and not a terminal state: RB allows a husrannsakan
    -- to be resumed, so a measure stays valid after it has been carried out.
    `verkstalld_at` DATETIME(3)   NULL,
    `verkstalld_by` VARCHAR(32)   NULL,
    `verkstalld_note` VARCHAR(500) NULL,

    -- Revocation, which overrides the window.
    `upphavd_at`  DATETIME(3)     NULL,
    `upphavd_by`  VARCHAR(32)     NULL,

    `classification` VARCHAR(16)  NOT NULL DEFAULT 'internal',
    `version`     INT UNSIGNED    NOT NULL DEFAULT 1,
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_tvang_number` (`agency_id`, `number`),
    UNIQUE KEY `uq_fpd_tvang_id_agency` (`id`, `agency_id`),
    -- The index the spec 14 export reads. Target first, because the question at
    -- a door is always about one target; then the window, so a live measure is
    -- found without reading the ones that have lapsed.
    KEY `idx_fpd_tvang_valid` (`agency_id`, `target_kind`, `target_id`, `valid_until`),
    KEY `idx_fpd_tvang_fu` (`fu_id`),
    CONSTRAINT `fk_fpd_tvang_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_tvang_fu` FOREIGN KEY (`fu_id`)
        REFERENCES `fpd_forundersokning` (`id`) ON DELETE SET NULL,
    CONSTRAINT `ck_fpd_tvang_kind` CHECK (`kind` IN
        ('husrannsakan_reell', 'husrannsakan_personell',
         'kroppsvisitation', 'kroppsbesiktning', 'beslag')),
    CONSTRAINT `ck_fpd_tvang_target` CHECK (`target_kind` IN
        ('person', 'vehicle', 'address')),
    -- All three capacities, for the reason the header gives: RB gives the
    -- ordinary husrannsakan to the police FU-ledare, and forcing a judge would
    -- stop the commonest measure in the suite.
    CONSTRAINT `ck_fpd_tvang_decider` CHECK (`decider_kind` IN
        ('fu_ledare', 'aklagare', 'domare')),
    CONSTRAINT `ck_fpd_tvang_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret')),
    -- A window that ends before it starts authorises nothing and would read as
    -- a live measure to anybody comparing only one end of it.
    CONSTRAINT `ck_fpd_tvang_window` CHECK (`valid_until` > `valid_from`),
    CONSTRAINT `ck_fpd_tvang_number` CHECK (CHAR_LENGTH(TRIM(`number`)) > 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Efterlysning
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_efterlysning` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `number`      VARCHAR(32)     NOT NULL COMMENT 'Counter kind `warrant` (Appendix D)',

    `person_id`   BIGINT UNSIGNED NOT NULL,

    -- Why. `anhallen_i_franvaro` is the commonest and links to the chain in
    -- 0010, which is where the prosecutor's decision actually lives.
    `grund`       VARCHAR(32)     NOT NULL,
    `frihet_id`   BIGINT UNSIGNED NULL,
    `fu_id`       BIGINT UNSIGNED NULL,

    `note`        VARCHAR(500)    NULL,
    `priority`    TINYINT UNSIGNED NOT NULL DEFAULT 3 COMMENT '1 highest, 4 lowest',

    `issued_by`   VARCHAR(32)     NOT NULL,
    `issued_at`   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `expires_at`  DATETIME(3)     NULL COMMENT 'NULL means it stands until cancelled',

    -- How it ended. Both columns or neither: an efterlysning that is no longer
    -- live has to say who took it off, or nobody can be asked why somebody
    -- stopped being wanted.
    `cancelled_at` DATETIME(3)    NULL,
    `cancelled_by` VARCHAR(32)    NULL,
    `cancelled_grund` VARCHAR(128) NULL COMMENT 'Locale key',

    `classification` VARCHAR(16)  NOT NULL DEFAULT 'internal',
    `version`     INT UNSIGNED    NOT NULL DEFAULT 1,

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_efterlysning_number` (`agency_id`, `number`),
    UNIQUE KEY `uq_fpd_efterlysning_id_agency` (`id`, `agency_id`),
    -- The hot-file index (7.2). Person first: every query resolves to a person
    -- and then asks this one question about them.
    KEY `idx_fpd_efterlysning_live` (`person_id`, `cancelled_at`, `expires_at`),
    KEY `idx_fpd_efterlysning_agency` (`agency_id`, `cancelled_at`),
    CONSTRAINT `fk_fpd_efterlysning_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_efterlysning_person` FOREIGN KEY (`person_id`)
        REFERENCES `fpd_persons` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_efterlysning_frihet` FOREIGN KEY (`frihet_id`)
        REFERENCES `fpd_frihetsberovande` (`id`) ON DELETE SET NULL,
    CONSTRAINT `fk_fpd_efterlysning_fu` FOREIGN KEY (`fu_id`)
        REFERENCES `fpd_forundersokning` (`id`) ON DELETE SET NULL,
    CONSTRAINT `ck_fpd_efterlysning_grund` CHECK (`grund` IN
        ('anhallen_i_franvaro', 'haktad_i_franvaro', 'delgivning',
         'forsvunnen', 'oidentifierad', 'annan')),
    CONSTRAINT `ck_fpd_efterlysning_priority` CHECK (`priority` BETWEEN 1 AND 4),
    CONSTRAINT `ck_fpd_efterlysning_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret')),
    CONSTRAINT `ck_fpd_efterlysning_cancelled` CHECK (
        (`cancelled_at` IS NULL AND `cancelled_by` IS NULL)
        OR (`cancelled_at` IS NOT NULL AND `cancelled_by` IS NOT NULL)),
    CONSTRAINT `ck_fpd_efterlysning_number` CHECK (CHAR_LENGTH(TRIM(`number`)) > 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- ============================================================
-- 0012_spaning.sql
-- ============================================================
-- 0012_spaning.sql
--
-- Spaningsuppdrag, and the hot-file sources that were missing from 0006
-- (spec 7.2, 7.13; milestone M2).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
--
-- =============================================================================
-- SPANINGSUPPDRAG IS NOT EFTERLYSNING, AND BOTH ARE 7.13
-- =============================================================================
--
-- 7.13 asks for "BOLOs and attempts to locate", which Appendix A translates as
-- **spaningsuppdrag**. 0011 already built **efterlysning**, and the two are
-- genuinely different things rather than one thing named twice:
--
--   * An **efterlysning** is a legal status. Somebody is wanted because a
--     prosecutor decided to anhålla them in their absence, or a court häktade
--     them in their absence. Issuing one is a command-level act, it names a
--     person in the master index, and it means *detain this person*.
--   * A **spaningsuppdrag** is an operational lookout. Any officer may raise
--     one, it may name a **vehicle** as easily as a person, it carries an area
--     and a description, and it means *look for this and tell us*. A stolen car
--     that nobody has been charged over is a spaningsuppdrag; so is "this van
--     was seen leaving the scene".
--
-- Keeping them apart is what lets the hit banner say something useful. Merging
-- them would mean either raising a detain-on-sight banner for a van somebody
-- wants a second look at, or burying a prosecutor's decision among sightings.
--
--
-- =============================================================================
-- THE TARGET, AND WHY IT IS NOT A FOREIGN KEY
-- =============================================================================
--
-- A spaningsuppdrag may name a person, a vehicle, **or neither**. The last is
-- the case a foreign key cannot express and the one the module exists for: a
-- description with no record behind it -- "silver estate, no plate seen, three
-- occupants" -- is the commonest lookout there is, and a schema that demanded a
-- registered vehicle would refuse to record it.
--
-- So `target_kind` and `target_id` follow the shape `fpd_call_links` uses in
-- 0007, `target_id` is nullable, and `description` carries the case where there
-- is nothing to point at. `ck_fpd_spaning_target` is what stops the pair being
-- meaningless: a row naming a `vehicle` with no id and no description would be
-- a lookout for nothing at all.
--
--
-- =============================================================================
-- WIDENING THE HOT-FILE CONFIRMATION (0006)
-- =============================================================================
--
-- 7.2 requires a confirmation step on every hot-file hit, and 0006 built it for
-- the three sources that existed then: a vehicle flag, a firearm status and a
-- person caution. Two more exist now -- an efterlysning (0011) and a
-- spaningsuppdrag (this file) -- and they are the two that most need
-- confirming, because they are the ones that end with an officer stopping
-- somebody.
--
-- 0006 has shipped and is not edited (invariant 8). The constraints are
-- replaced here instead. `DROP CONSTRAINT IF EXISTS` then `ADD` is idempotent,
-- which is what CI's second pass over this file requires.

-- -----------------------------------------------------------------------------
-- Spaningsuppdrag
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_spaning` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `number`      VARCHAR(32)     NOT NULL COMMENT 'Counter kind `bolo` (Appendix D)',

    `target_kind` VARCHAR(16)     NOT NULL,
    `target_id`   BIGINT UNSIGNED NULL COMMENT 'NULL when there is no record to point at',

    -- What to look for when there is no record, and the detail that is worth
    -- reading even when there is. Free text: this is one officer describing
    -- what they saw to another, which is the one kind of string that cannot be
    -- a locale key.
    `description` VARCHAR(500)    NULL,

    -- Why, as a locale key (invariant 6), and how urgent.
    `grund`       VARCHAR(128)    NOT NULL,
    `priority`    TINYINT UNSIGNED NOT NULL DEFAULT 3 COMMENT '1 highest, 4 lowest',

    -- Where to look. A beat, so it joins the dispatch geography rather than
    -- inventing a second one, and nullable because plenty of lookouts are
    -- force-wide.
    `beat_id`     BIGINT UNSIGNED NULL,
    `area_note`   VARCHAR(191)    NULL,

    `fu_id`       BIGINT UNSIGNED NULL,
    `anmalan_id`  BIGINT UNSIGNED NULL,

    `issued_by`   VARCHAR(32)     NOT NULL,
    `issued_at`   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    -- An expiry is **required** here, unlike an efterlysning's. A legal
    -- decision does not lapse because time passed; a lookout does, and one that
    -- never expires is a banner that stays on the screen until somebody
    -- remembers a van from three months ago. The default is set by the module.
    `expires_at`  DATETIME(3)     NOT NULL,

    `resolved_at` DATETIME(3)     NULL,
    `resolved_by` VARCHAR(32)     NULL,
    `resolved_grund` VARCHAR(128) NULL COMMENT 'Locale key',

    `classification` VARCHAR(16)  NOT NULL DEFAULT 'internal',
    `version`     INT UNSIGNED    NOT NULL DEFAULT 1,

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_spaning_number` (`agency_id`, `number`),
    UNIQUE KEY `uq_fpd_spaning_id_agency` (`id`, `agency_id`),
    -- The hot-file index. Target first, because every query resolves to one
    -- and then asks this question about it; then the two columns that decide
    -- whether the lookout is still live.
    KEY `idx_fpd_spaning_live` (`target_kind`, `target_id`, `resolved_at`, `expires_at`),
    KEY `idx_fpd_spaning_agency` (`agency_id`, `resolved_at`, `priority`),
    CONSTRAINT `fk_fpd_spaning_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_spaning_beat` FOREIGN KEY (`beat_id`)
        REFERENCES `fpd_beats` (`id`) ON DELETE SET NULL,
    CONSTRAINT `fk_fpd_spaning_fu` FOREIGN KEY (`fu_id`)
        REFERENCES `fpd_forundersokning` (`id`) ON DELETE SET NULL,
    CONSTRAINT `fk_fpd_spaning_anmalan` FOREIGN KEY (`anmalan_id`)
        REFERENCES `fpd_anmalan` (`id`) ON DELETE SET NULL,
    CONSTRAINT `ck_fpd_spaning_target` CHECK (`target_kind` IN
        ('person', 'vehicle', 'other')),
    -- A lookout has to be for *something*. A row with no record to point at and
    -- no description is a banner that says nothing.
    CONSTRAINT `ck_fpd_spaning_something` CHECK (
        `target_id` IS NOT NULL OR CHAR_LENGTH(TRIM(COALESCE(`description`, ''))) > 0),
    CONSTRAINT `ck_fpd_spaning_priority` CHECK (`priority` BETWEEN 1 AND 4),
    CONSTRAINT `ck_fpd_spaning_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret')),
    CONSTRAINT `ck_fpd_spaning_resolved` CHECK (
        (`resolved_at` IS NULL AND `resolved_by` IS NULL)
        OR (`resolved_at` IS NOT NULL AND `resolved_by` IS NOT NULL)),
    CONSTRAINT `ck_fpd_spaning_window` CHECK (`expires_at` > `issued_at`),
    CONSTRAINT `ck_fpd_spaning_number` CHECK (CHAR_LENGTH(TRIM(`number`)) > 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- The two hot-file sources 0006 could not know about
-- -----------------------------------------------------------------------------

-- Replacing a CHECK rather than editing 0006 (invariant 8). Idempotent, so
-- CI's second pass is a no-op.
--
-- `efterlysning` and `spaning` are added to both lists. `record_type` gains
-- them as well, because the confirmation route runs the access check for the
-- named record type before it writes, and a hit on a record type it does not
-- recognise would be refused with no way to confirm it -- which for these two
-- means an officer who cannot record that they checked before acting.

ALTER TABLE `fpd_hotfile_confirmations`
    DROP CONSTRAINT IF EXISTS `ck_fpd_hotfile_confirmations_hit_type`;

ALTER TABLE `fpd_hotfile_confirmations`
    ADD CONSTRAINT `ck_fpd_hotfile_confirmations_hit_type` CHECK (`hit_type` IN
        ('vehicle_flag', 'firearm', 'person_caution', 'efterlysning', 'spaning'));

ALTER TABLE `fpd_hotfile_confirmations`
    DROP CONSTRAINT IF EXISTS `ck_fpd_hotfile_confirmations_record_type`;

ALTER TABLE `fpd_hotfile_confirmations`
    ADD CONSTRAINT `ck_fpd_hotfile_confirmations_record_type` CHECK (`record_type` IN
        ('vehicle', 'firearm', 'person', 'efterlysning', 'spaning'));

-- ============================================================
-- 0013_records_indexes.sql
-- ============================================================
-- 0013_records_indexes.sql
--
-- Indexes for the records half of M2 (spec 7.7-7.13, section 12 budgets).
--
-- Invariant 8: append-only. Never edit this file once it has shipped. These
-- indexes are a separate migration rather than an edit to 0009-0011 for exactly
-- that reason -- the tables they cover have already shipped.
--
--
-- =============================================================================
-- WHY THESE SIX, AND NOT THE ONES 0009-0011 ALREADY HAVE
-- =============================================================================
--
-- The indexes written alongside the tables cover the *filters*. Every list in
-- this half of M2 also has an **order**, and MariaDB can only walk an index in
-- order when the ordering column follows the equality columns in that same
-- index. A `(agency_id, status)` index answers `WHERE agency_id = ? AND status
-- = ?` off the index and then sorts the whole result by hand, which is the
-- `Using filesort` that showed up on every one of these plans.
--
-- Measured against MariaDB 11.4 with 50k tvångsmedel, 50k anmälningar, 50k
-- frihetsberövanden and 20k förundersökningar -- the size a busy server reaches
-- in a year, not a worst case:
--
--   | query                       | before   | after   | plan before        |
--   |-----------------------------|----------|---------|--------------------|
--   | HasSearchWarrant (per door) |  25.3 ms | 0.84 ms | index scan, 49554  |
--   | anmalan.list                | 480.0 ms | 2.67 ms | filesort, 25000    |
--   | frihet.list                 |  83.0 ms | 1.06 ms | filesort, 25000    |
--   | fu.list                     |  16.7 ms | 0.92 ms | filesort, 10000    |
--
-- `Using filesort` is gone from all four plans, and the row estimate on the
-- door scan drops from 49554 to 3.
--
-- The anmälan figure is with `handelseforlopp` still in the list SELECT, which
-- is the other half of that fix and lives in `anmalan/repo.lua`: a list of
-- fifty reports does not need fifty editor documents, and dropping the column
-- takes the same query from 2.67 ms to 0.86 ms. The index is what stops the
-- server reading 25000 of those blobs to find the newest fifty.
--
--
-- =============================================================================
-- THE DOOR SCAN IS THE ONE THAT MATTERS
-- =============================================================================
--
-- `HasSearchWarrant(targetKind, targetId)` (spec 14) is the export a raid or
-- door script calls, and it calls it **per interaction** -- so this is the one
-- query here whose cost lands on a player holding a door open, not on somebody
-- who has chosen to open a list.
--
-- It reads `Repo.forTargetAnyAgency`, which deliberately has no agency in its
-- WHERE clause: a decision by one department does not stop authorising an
-- entry because a second department exists on the server. `idx_fpd_tvang_valid`
-- leads with `agency_id`, so that query could not use it at all and scanned
-- every measure the server had ever recorded. `idx_fpd_tvang_target` is the
-- same index without the agency in front.
--
-- `fpd_spaning` already had this shape right (`idx_fpd_spaning_live` leads with
-- the target, not the agency); this brings `fpd_tvangsmedel` into line with it.
--
--
-- =============================================================================
-- WHAT IS DELIBERATELY NOT HERE
-- =============================================================================
--
--   * **`fpd_efterlysning` and `fpd_spaning` list ordering.** Both order by
--     `priority ASC, issued_at DESC`, and an ascending index cannot serve a
--     mixed-direction sort. The set being sorted is the *live* one -- people
--     actually wanted, lookouts actually running -- which is tens of rows per
--     agency, not tens of thousands, so the filesort is over a page of data and
--     the index would cost more to maintain than it saves.
--   * **`fpd_frihetsberovande` open list.** `Repo.open` filters `status <>
--     'frigiven'`, a range rather than an equality, so no index can carry the
--     ordering past it. The set is everybody currently in custody, which is
--     bounded by the number of cells.
--   * **`anmalan.list` filtered by `mine`.** `idx_fpd_anmalan_author` answers
--     the filter and one officer's reports are few enough to sort.

-- -----------------------------------------------------------------------------
-- Tvångsmedel (7.12)
-- -----------------------------------------------------------------------------

-- The spec 14 export, across every agency.
ALTER TABLE `fpd_tvangsmedel`
    ADD KEY IF NOT EXISTS `idx_fpd_tvang_target` (`target_kind`, `target_id`, `valid_until`);

-- `Repo.list`: WHERE agency_id = ? ORDER BY created_at DESC.
ALTER TABLE `fpd_tvangsmedel`
    ADD KEY IF NOT EXISTS `idx_fpd_tvang_recent` (`agency_id`, `created_at`);

-- -----------------------------------------------------------------------------
-- Anmälan (7.7)
-- -----------------------------------------------------------------------------

-- The default Records list: WHERE agency_id = ? AND parent_id IS NULL
-- ORDER BY created_at DESC.
--
-- `parent_id` sits in the middle because `IS NULL` is an equality as far as an
-- index is concerned -- tilläggsuppgifter are hidden from the top-level list by
-- default (they belong under their parent), so the predicate is on nearly every
-- call and leaving it out would put the sort back.
ALTER TABLE `fpd_anmalan`
    ADD KEY IF NOT EXISTS `idx_fpd_anmalan_recent` (`agency_id`, `parent_id`, `created_at`);

-- The same list with a status filter, which is how a supervisor finds what is
-- waiting for approval. `parent_id IS NULL` becomes a filter applied as the
-- index is walked, which costs a few extra row reads and keeps the ordering.
ALTER TABLE `fpd_anmalan`
    ADD KEY IF NOT EXISTS `idx_fpd_anmalan_status_recent` (`agency_id`, `status`, `created_at`);

-- -----------------------------------------------------------------------------
-- Förundersökning (7.8)
-- -----------------------------------------------------------------------------

ALTER TABLE `fpd_forundersokning`
    ADD KEY IF NOT EXISTS `idx_fpd_fu_recent` (`agency_id`, `opened_at`);

-- -----------------------------------------------------------------------------
-- Frihetsberövande (7.9)
-- -----------------------------------------------------------------------------

-- `Repo.list` -- the history, not `Repo.open`. A detention is never deleted, so
-- this table only grows, and it is the one a defence lawyer's question is
-- answered from months later.
ALTER TABLE `fpd_frihetsberovande`
    ADD KEY IF NOT EXISTS `idx_fpd_frihet_recent` (`agency_id`, `created_at`);

-- ============================================================
-- 0014_records_indexes_2.sql
-- ============================================================
-- -----------------------------------------------------------------------------
-- 0014 — the indexes the three new Records screens need
-- -----------------------------------------------------------------------------
--
-- 0013 indexed the lists that existed when it was written. Three of the four
-- screens built since open on a query it did not cover, and each was measured
-- over section 12's 50 ms route budget before this file existed — at 50k rows
-- per table, which 0013's header calls "the size a busy server reaches in a
-- year, not a worst case".
--
-- Measured on MariaDB 10.11, 50k spaning / 50k tvångsmedel / 50k efterlysning /
-- 10k persons, the SQL alone and before access filtering or the audit write:
--
--   | query                                   | before  | after   |
--   | --------------------------------------- | ------- | ------- |
--   | spaning.list, the screen's opening state | 62.4 ms |  1.3 ms |
--   | tvang.list, kind + liveOnly              | 56.4 ms | 13.8 ms |
--   | efterlysning.list, includeCancelled      | 63.4 ms |  0.5 ms |
--   | efterlysning.list, the default live read  | 56.3 ms | 16.6 ms |
--   | IsWanted's person lookup                 |  1.8 ms |  0.2 ms |
--
-- 0013 explicitly decided *against* a spaning index, on the grounds that "the
-- set being sorted is the live one — lookouts actually running — which is tens
-- of rows per agency". That premise was wrong, and the reason is worth keeping:
-- the set the sort has to walk is the set the WHERE clause can *reach with an
-- index*, which was the unresolved set rather than the live one. Nothing marks
-- a lapsed lookout as resolved — `resolved_at` is only written when an officer
-- closes one or when the target is found — so the unresolved set grows without
-- bound while the live set stays at tens of rows. The index below puts the
-- expiry where the range scan can use it, which is what makes the two sets the
-- same size again.
--
-- Idempotent, because CI applies every migration twice (§15).

-- -----------------------------------------------------------------------------
-- Spaningsuppdrag: the list as the screen opens it
-- -----------------------------------------------------------------------------
--
-- `idx_fpd_spaning_agency (agency_id, resolved_at, priority)` could range on
-- the first two columns and then had to read the clustered row for every
-- candidate to test `expires_at` — 45,000 row lookups to return 30 rows.
-- `expires_at` before `priority`: the expiry is what removes rows, and a
-- filesort over a page of live lookouts costs nothing.
ALTER TABLE `fpd_spaning`
    ADD KEY IF NOT EXISTS `idx_fpd_spaning_agency_live`
        (`agency_id`, `resolved_at`, `expires_at`);

-- -----------------------------------------------------------------------------
-- Tvångsmedel: the list with a measure kind selected
-- -----------------------------------------------------------------------------
--
-- `kind` was in no index at all, so filtering by one walked
-- `idx_fpd_tvang_recent` backwards with a clustered lookup per entry. The
-- dangerous pair is `kind` with "in force only", because live measures are a
-- small and recent set: a kind with twelve live matches read all fifty
-- thousand of the agency's rows to find them.
--
-- `created_at` last, so it still serves the ORDER BY once `kind` has been
-- matched — the same shape as `idx_fpd_tvang_recent`, one column deeper.
ALTER TABLE `fpd_tvangsmedel`
    ADD KEY IF NOT EXISTS `idx_fpd_tvang_kind_recent`
        (`agency_id`, `kind`, `created_at`);

-- -----------------------------------------------------------------------------
-- Efterlysning: the history read, and the live list that never filtered expiry
-- -----------------------------------------------------------------------------
--
-- Two problems, one index. The default list filters `cancelled_at IS NULL` and
-- nothing else — a notice that lapsed last March is still read, still joined to
-- `fpd_persons`, still sorted and then drawn as "lapsed". And with "include
-- lifted" ticked the WHERE collapses to the agency alone, which is a filesort
-- and a join per row over every wanted notice the agency has ever issued.
--
-- `expires_at` is nullable on purpose — NULL means "stands until lifted", which
-- is the right default for a prosecutor's decision — and a NULL sorts first in
-- an InnoDB index, so a range on `expires_at > now` would drop exactly the
-- notices that never expire. The repo therefore keeps liveness in
-- `Tvang.isLive` and this index only has to make the rows cheap to reach.
ALTER TABLE `fpd_efterlysning`
    ADD KEY IF NOT EXISTS `idx_fpd_efterlysning_agency_live`
        (`agency_id`, `cancelled_at`, `expires_at`);

-- And the sort, which is the half an index on the filter cannot serve.
--
-- The ORDER BY is `priority ASC, issued_at DESC` — a *mixed direction*, which
-- 0013's header named as the reason it left these lists alone. An all-ascending
-- index cannot serve it, so MariaDB filesorted twenty-five thousand rows to
-- return fifty, whatever else was indexed. A descending column can (MariaDB
-- 10.8+), and with it the history read drops from 63.4 ms to 0.5 ms and the
-- filesort disappears from the plan entirely.
ALTER TABLE `fpd_efterlysning`
    ADD KEY IF NOT EXISTS `idx_fpd_efterlysning_sorted`
        (`agency_id`, `priority`, `issued_at` DESC);

-- -----------------------------------------------------------------------------
-- Persons: the identifier lookup `IsWanted` runs
-- -----------------------------------------------------------------------------
--
-- `uq_fpd_persons_identifier` is `(agency_id, identifier)`, so a WHERE on the
-- identifier alone cannot use it — and `IsWanted(citizenid)` deliberately drops
-- the agency, because the question it answers is whether *anybody* wants this
-- person and a two-force server must not have two blind spots.
--
-- The result was a full scan of `fpd_persons` on an export other resources call
-- per interaction: the same class of defect 0013 fixed for `HasSearchWarrant`,
-- in the export beside it, and missed because the scan is cheap until the name
-- index is large.
--
-- Not unique: the same ESX character may hold a master record in each agency,
-- which is precisely what the export walks.
ALTER TABLE `fpd_persons`
    ADD KEY IF NOT EXISTS `idx_fpd_persons_identifier` (`identifier`);

-- ============================================================
-- 0015_surveillance.sql
-- ============================================================
-- 0015_surveillance.sql
--
-- Hemlig avlyssning och annan hemlig tvångsmedelsanvändning: HAK, HRA,
-- spårsändare, kameraövervakning (spec 9; milestone M5).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
--
-- =============================================================================
-- WHY THIS TABLE HAS A JUDGE AND 0011's DOES NOT
-- =============================================================================
--
-- 0011 argued at length that Swedish procedure gives the ordinary coercive
-- measures -- husrannsakan, kroppsvisitation -- to the förundersökningsledare,
-- police or prosecutor, and a court only where RB actually requires one. The
-- secret measures are exactly that "where RB requires one": hemlig
-- avlyssning av elektronisk kommunikation (RB 27:18), hemlig
-- rumsavlyssning (RB 27:20d), and the spårsändare and kameraövervakning
-- FredPD adds alongside them are **tingsrätt-decided**, on the åklagare's
-- application, precisely because they reach somebody who does not know they
-- are being watched and cannot object before the fact. That is also why this
-- table's shape mirrors 0010's häktning stage rather than 0011's single
-- decision: an åklagare applies, and only a domare's grant makes it live.
--
--
-- =============================================================================
-- REQUEST, THEN DECISION -- NOT ONE STEP
-- =============================================================================
--
-- `status` walks `begard` (requested) -> `beviljad` (granted) or `avslagen`
-- (refused) -> optionally `upphavd` (revoked before its window ran out, RB
-- 27:23 -- grounds may cease before the window does). `ck_fpd_hak_chain`
-- enforces that each stage's columns are actually filled, the same reasoning
-- 0010's `ck_fpd_frihet_chain` uses for the frihetsberövande chain. There is
-- no `verkstalld` stage here: unlike a husrannsakan, a granted interception
-- does not wait to be "carried out" as a separate recorded act -- observing
-- starts as soon as `fpd_hak_sessions` gets a row, which is exactly what that
-- table is for.
--
--
-- =============================================================================
-- WHAT IS DELIBERATELY NOT HERE
-- =============================================================================
--
-- **Media.** `fpd_hak_intercepts.media_ref` is a reference, never a URL
-- (invariant 9, spec 3.7) -- the gateway resolves it to a signed link when C1
-- of the remaining-work plan builds media upload. Nothing here presumes its
-- shape beyond a string.
--
-- **A dedicated access-read log.** `Repo.access.read` already audits every
-- restricted read against the generic append-only audit log (invariant 11),
-- and `surveillance` has been in `RECORD_TYPES` (0001, `access/repo.lua`)
-- since M1 for exactly this. A second, per-module log table here would be a
-- second definition of "who read this", and the two would drift the way
-- 0013's header warns fixtures do. `fpd_hak_intercepts` is a case journal --
-- what was captured -- not an access log; those are different questions, and
-- 0010's `fpd_frihet_log` is the same distinction for the frihetsberövande
-- chain.

-- -----------------------------------------------------------------------------
-- The decision
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_hak` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `number`      VARCHAR(32)     NOT NULL COMMENT 'Counter kind `hak` (Appendix D)',

    -- A secret measure is always taken inside an investigation; there is no
    -- "no FU" case the way an ordinary husrannsakan sometimes has one.
    `fu_id`       BIGINT UNSIGNED NOT NULL,

    `target_kind` VARCHAR(16)     NOT NULL,
    -- Set only when the target is a record FredPD already holds (a person, a
    -- vehicle). A telephone number or an address is not a foreign key into
    -- anything, so `target_label` (below) is what most rows actually carry.
    `target_id`   BIGINT UNSIGNED NULL,
    -- The phone number, the room, the vehicle's description -- whatever a
    -- court decision names that is not one of this suite's own ids. Free
    -- text, like `fpd_tvangsmedel.target_label`.
    `target_label` VARCHAR(191)   NULL,

    `method`      VARCHAR(24)     NOT NULL,

    -- Why, as a locale key (invariant 6), never a sentence -- the NUI renders
    -- it with `t()` for both the åklagare's application and the domare's
    -- reading of it.
    `grund`       VARCHAR(128)    NOT NULL,

    `status`      VARCHAR(16)     NOT NULL DEFAULT 'begard',

    `requested_by` VARCHAR(32)    NOT NULL COMMENT 'Discord id of the åklagare',
    `requested_at` DATETIME(3)    NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    `decided_by`  VARCHAR(32)     NULL COMMENT 'Discord id of the domare',
    `decided_at`  DATETIME(3)     NULL,
    `refused_grund` VARCHAR(128)  NULL COMMENT 'Locale key, set only when avslagen',

    -- The court's own reference for its beslut -- what an åklagare or domare
    -- would quote if asked to justify this outside the game.
    `court_ref`   VARCHAR(64)     NULL,

    -- The window. NULL until granted; `Surveillance.isValid` is the one
    -- definition of "live", the same split 0011 makes for `Tvang.isValid`.
    `valid_from`  DATETIME(3)     NULL,
    `valid_until` DATETIME(3)     NULL,

    `upphavd_at`  DATETIME(3)     NULL,
    `upphavd_by`  VARCHAR(32)     NULL,
    `upphavd_grund` VARCHAR(128)  NULL COMMENT 'Locale key: why RB 27:23 was invoked',

    `classification` VARCHAR(16)  NOT NULL DEFAULT 'confidential',
    `version`     INT UNSIGNED    NOT NULL DEFAULT 1,
    `updated_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_hak_number` (`agency_id`, `number`),
    UNIQUE KEY `uq_fpd_hak_id_agency` (`id`, `agency_id`),
    KEY `idx_fpd_hak_fu` (`fu_id`),
    -- The list an åklagare or domare reads: their own agency's open requests
    -- and grants, most recent first.
    KEY `idx_fpd_hak_agency_status` (`agency_id`, `status`, `requested_at`),
    -- The liveness question -- is there a live measure on this target --
    -- mirroring `idx_fpd_tvang_valid`'s shape.
    KEY `idx_fpd_hak_target_valid` (`target_kind`, `target_id`, `valid_until`),
    CONSTRAINT `fk_fpd_hak_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_hak_fu` FOREIGN KEY (`fu_id`)
        REFERENCES `fpd_forundersokning` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `ck_fpd_hak_target` CHECK (`target_kind` IN
        ('person', 'phone', 'vehicle', 'location')),
    CONSTRAINT `ck_fpd_hak_method` CHECK (`method` IN
        ('hak', 'hra', 'sparsandare', 'kameraovervakning')),
    CONSTRAINT `ck_fpd_hak_status` CHECK (`status` IN
        ('begard', 'beviljad', 'avslagen', 'upphavd')),
    CONSTRAINT `ck_fpd_hak_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret')),
    -- A target has to be *something*: a record this suite already holds, or a
    -- label naming what it does not (a phone number, a room). The same
    -- reasoning as `ck_fpd_spaning_something`.
    CONSTRAINT `ck_fpd_hak_something` CHECK (
        `target_id` IS NOT NULL OR CHAR_LENGTH(TRIM(COALESCE(`target_label`, ''))) > 0),
    -- The chain: each stage requires its own decision-maker and, for a grant,
    -- the window it authorises.
    CONSTRAINT `ck_fpd_hak_chain` CHECK (
        (`status` <> 'begard'   OR (`requested_at` IS NOT NULL AND `requested_by` IS NOT NULL))
        AND (`status` <> 'beviljad' OR (`decided_at` IS NOT NULL AND `decided_by` IS NOT NULL
                                        AND `valid_from` IS NOT NULL AND `valid_until` IS NOT NULL))
        AND (`status` <> 'avslagen' OR (`decided_at` IS NOT NULL AND `decided_by` IS NOT NULL))
        AND (`status` <> 'upphavd'  OR (`upphavd_at` IS NOT NULL AND `upphavd_by` IS NOT NULL
                                        AND `decided_at` IS NOT NULL))),
    CONSTRAINT `ck_fpd_hak_window` CHECK (
        `valid_from` IS NULL OR `valid_until` IS NULL OR `valid_until` > `valid_from`),
    CONSTRAINT `ck_fpd_hak_number` CHECK (CHAR_LENGTH(TRIM(`number`)) > 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Observer sessions
-- -----------------------------------------------------------------------------

-- Written by the server the moment an authorized observer starts listening
-- and again when they stop (spec 9's "sessions are written by the server").
-- No client ever sends a session row; it is a consequence of a route call,
-- the same way `fpd_frihet_log` is.

CREATE TABLE IF NOT EXISTS `fpd_hak_sessions` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `hak_id`      BIGINT UNSIGNED NOT NULL,

    `observer`    VARCHAR(32)     NOT NULL COMMENT 'Discord id',
    `started_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `ended_at`    DATETIME(3)     NULL,
    -- Spec 9's "product log with minimization notes": what was relevant and
    -- what was not, the record an observer keeps to show they did not listen
    -- past what the decision authorised.
    `minimization_note` VARCHAR(500) NULL,

    PRIMARY KEY (`id`),
    KEY `idx_fpd_hak_sessions_hak` (`hak_id`, `started_at`),
    -- The open-session question: is anybody listening right now. Short list,
    -- narrow index, the same shape as `idx_fpd_frihet_open`.
    KEY `idx_fpd_hak_sessions_open` (`observer`, `ended_at`),
    CONSTRAINT `fk_fpd_hak_sessions_hak` FOREIGN KEY (`hak_id`)
        REFERENCES `fpd_hak` (`id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_hak_sessions_order` CHECK (
        `ended_at` IS NULL OR `ended_at` >= `started_at`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Captures
-- -----------------------------------------------------------------------------

-- Append-only, like `fpd_frihet_log` and for the same reason: the question
-- asked about an interception afterwards is always "what was captured, and
-- when", and a row that could be edited answers it with what somebody would
-- prefer had been captured.

CREATE TABLE IF NOT EXISTS `fpd_hak_intercepts` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `hak_id`      BIGINT UNSIGNED NOT NULL,

    -- A locale key naming what kind of capture this is (call, message,
    -- position, audio, image, …), for the same reason `fpd_frihet_log.kind`
    -- is one rather than an enum: what a method can capture is a matter of
    -- which methods a department has built out, not of what RB names, and a
    -- CHECK here would need a migration before a server could log its own
    -- interceptions.
    `kind`        VARCHAR(64)     NOT NULL,
    `occurred_at` DATETIME(3)     NOT NULL,
    `summary`     VARCHAR(500)    NULL COMMENT 'Free text: an observer describing what was captured',
    -- A reference, never a URL (invariant 9). The gateway resolves this to a
    -- signed link; nothing here presumes what resolves it.
    `media_ref`   VARCHAR(191)    NULL,

    `classification` VARCHAR(16)  NOT NULL DEFAULT 'confidential',

    `logged_by`   VARCHAR(32)     NULL,
    `logged_at`   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    KEY `idx_fpd_hak_intercepts_hak` (`hak_id`, `occurred_at`),
    CONSTRAINT `fk_fpd_hak_intercepts_hak` FOREIGN KEY (`hak_id`)
        REFERENCES `fpd_hak` (`id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_hak_intercepts_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret')),
    CONSTRAINT `ck_fpd_hak_intercepts_kind` CHECK (CHAR_LENGTH(TRIM(`kind`)) > 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- ============================================================
-- 0016_court.sql
-- ============================================================
-- 0016_court.sql
--
-- Åtal och dom: the prosecutor's charging decision and the court's
-- disposition (spec 7.20; milestone M6).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
--
-- =============================================================================
-- WHAT ALREADY EXISTS, AND WHY THIS IS ONE NEW TABLE AND NOT TWO
-- =============================================================================
--
-- 7.20 reads like three things: a court calendar with hearings, a charging
-- decision, and a disposition with a sentence. The first of those already has
-- a decision-maker and a record: 0010's `fpd_frihetsberovande.haktning_beslut`
-- *is* the häktningsförhandling's outcome, decided by a domare, and a second
-- "hearing" table here would be a second place that fact lives. What 0010
-- does not cover is what spec 7.20 actually calls "M": the åklagare's
-- decision whether to väcka åtal at all once an FU is redovisad, and the
-- disposition that follows it. That is what `fpd_atal` is.
--
-- One table, not two, because a charging decision and its disposition are one
-- fact told in two stages -- an åtal that never reaches disposition is not a
-- different kind of row, it is the same row with its second half still NULL.
-- `fpd_domar` was the name in the original sketch of this milestone; renamed
-- because a döm is not a separate record from the åtal it disposes of.
--
--
-- =============================================================================
-- WHY THE FU ITSELF IS UNTOUCHED
-- =============================================================================
--
-- `Repo.fuTransition` (0009) already stamps `closed_at`/`closed_by` on
-- `redovisad`, exactly as it does on `nedlagd` -- a redovisad FU is closed
-- from the investigation's own side. Adding an `atalad` status to
-- `ck_fpd_fu_status` would mean either re-deriving those columns for a state
-- that does not close anything a second time, or leaving them stale, and
-- either way it is a second definition of "this investigation is finished"
-- living in two tables. The FU says an investigation happened and ended; this
-- table says what the prosecutor did with what it produced. They are
-- different facts about different actors, and `fu_id` is the join.
--
-- **"Request more investigation"** (7.20's third outcome, alongside file and
-- decline) is not built here. It is a redovisad FU being reopened, which
-- 0009's schema and `Frihet`-style transition guards do not currently allow
-- from a closed state, and forcing it in without touching the FU's own
-- lifecycle would be the "second definition" problem this file exists to
-- avoid. Left for whoever revisits the FU lifecycle itself.
--
--
-- =============================================================================
-- THE SENTENCE, AND WHY IT IS TWO COLUMNS
-- =============================================================================
--
-- `Brott.gemensamStraffskala` (0008) already answers "what range may this
-- charge sheet be sentenced within", from the same `fpd_atal_brott` rows this
-- migration adds. A verdict's sentence is checked against that range in
-- `court/service.lua`, not re-derived here -- this table only stores what a
-- domare entered. Livstid is a real sentence and is not a number of months
-- (0008's own `Brott.LIVSTID = nil` argues why), so it is its own flag rather
-- than a sentinel value `sentence_months` might one day collide with.

-- -----------------------------------------------------------------------------
-- Åtal och dom
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_atal` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `number`      VARCHAR(32)     NOT NULL COMMENT 'Counter kind `atal` (Appendix D)',

    `fu_id`       BIGINT UNSIGNED NOT NULL COMMENT 'Must be redovisad when decided (service, not a CHECK)',

    -- The charging decision.
    `beslut`      VARCHAR(16)     NOT NULL COMMENT 'atalad | ej_atal',
    `beslut_grund` VARCHAR(128)   NULL COMMENT 'Locale key, required when ej_atal',
    `decided_by`  VARCHAR(32)     NOT NULL COMMENT 'Discord id of the åklagare',
    `decided_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    -- The disposition. NULL until a domare enters one, and only ever set on a
    -- row whose `beslut` is `atalad` (`ck_fpd_atal_disposition_needs_atal`).
    `disposition` VARCHAR(16)     NULL COMMENT 'guilty | not_guilty | dismissed | plea',
    `sentence_months` SMALLINT UNSIGNED NULL,
    `sentence_livstid` TINYINT(1) NOT NULL DEFAULT 0,
    `disposition_note` VARCHAR(500) NULL,
    `disposition_by` VARCHAR(32)  NULL COMMENT 'Discord id of the domare',
    `disposition_at` DATETIME(3)  NULL,

    `classification` VARCHAR(16)  NOT NULL DEFAULT 'internal',
    `version`     INT UNSIGNED    NOT NULL DEFAULT 1,
    `updated_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_atal_number` (`agency_id`, `number`),
    UNIQUE KEY `uq_fpd_atal_id_agency` (`id`, `agency_id`),
    -- One charging decision per investigation: a second åtal on the same FU
    -- would be a second prosecutor deciding the same referral, which is a
    -- correction to this row, not a new one.
    UNIQUE KEY `uq_fpd_atal_fu` (`fu_id`),
    KEY `idx_fpd_atal_agency` (`agency_id`, `beslut`, `decided_at`),
    CONSTRAINT `fk_fpd_atal_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_atal_fu` FOREIGN KEY (`fu_id`)
        REFERENCES `fpd_forundersokning` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `ck_fpd_atal_beslut` CHECK (`beslut` IN ('atalad', 'ej_atal')),
    -- No `IS NULL OR` prefix needed: a CHECK is satisfied whenever it
    -- evaluates to NULL rather than FALSE, and `disposition IN (…)` already
    -- does that for a NULL `disposition` on its own -- the same shape
    -- `enum-check.ts` expects a paired, client-facing enum to be written in.
    CONSTRAINT `ck_fpd_atal_disposition` CHECK (
        `disposition` IN ('guilty', 'not_guilty', 'dismissed', 'plea')),
    -- A declined referral has nothing to dispose of.
    CONSTRAINT `ck_fpd_atal_disposition_needs_atal` CHECK (
        `disposition` IS NULL OR `beslut` = 'atalad'),
    -- The disposition's own decision-maker travels with it, the same pairing
    -- 0012's `ck_fpd_spaning_resolved` uses.
    CONSTRAINT `ck_fpd_atal_disposition_decided` CHECK (
        (`disposition` IS NULL AND `disposition_by` IS NULL AND `disposition_at` IS NULL)
        OR (`disposition` IS NOT NULL AND `disposition_by` IS NOT NULL AND `disposition_at` IS NOT NULL)),
    CONSTRAINT `ck_fpd_atal_sentence` CHECK (
        `sentence_livstid` = 0 OR `sentence_months` IS NULL),
    CONSTRAINT `ck_fpd_atal_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret')),
    CONSTRAINT `ck_fpd_atal_number` CHECK (CHAR_LENGTH(TRIM(`number`)) > 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- The charges pursued
-- -----------------------------------------------------------------------------

-- One row per count, pointing at an immutable catalogue version -- the same
-- shape `fpd_anmalan_brott` (0009) and `fpd_frihet_brott` (0010) use, and for
-- the same reason: a verdict reads the way the statute read when it was
-- charged, whatever the catalogue says by the time anyone looks again.
--
-- A third copy of "which offences" rather than a reference to the anmälan's
-- or the frihet chain's own list, because an åtal may narrow either -- an
-- åklagare can charge fewer counts than the anmälan reported, or than the
-- gripande rested on -- and 0010's header makes the identical argument for
-- why its own list is not a reference to the anmälan's.

CREATE TABLE IF NOT EXISTS `fpd_atal_brott` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `atal_id`     BIGINT UNSIGNED NOT NULL,
    `brott_id`    BIGINT UNSIGNED NOT NULL COMMENT 'One catalogue version (0008)',
    `stage`       VARCHAR(16)     NOT NULL DEFAULT 'fullbordat',

    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    KEY `idx_fpd_atal_brott_atal` (`atal_id`),
    KEY `idx_fpd_atal_brott_brott` (`brott_id`),
    CONSTRAINT `fk_fpd_atal_brott_atal` FOREIGN KEY (`atal_id`)
        REFERENCES `fpd_atal` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_atal_brott_brott` FOREIGN KEY (`brott_id`)
        REFERENCES `fpd_brott` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `ck_fpd_atal_brott_stage` CHECK (`stage` IN
        ('fullbordat', 'forsok', 'forberedelse', 'stampling'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- ============================================================
-- 0017_personnel.sql
-- ============================================================
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

-- ============================================================
-- 0018_booking.sql
-- ============================================================
-- 0018_booking.sql
--
-- Inskrivning i arrest: cell assignment and the property inventory (spec 7.9;
-- milestone M6).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
--
-- =============================================================================
-- WHERE THE GRIPANDE CHAIN STOPS, AND WHERE THIS PICKS IT UP
-- =============================================================================
--
-- 0010's own header names this migration before it existed: "Inskrivning i
-- arrest (booking): the mugshot, the ten-print capture and the property
-- inventory of 7.9's second half. That is M6 ... A frihetsberövande row will
-- link to it when it exists; nothing here presumes its shape." This is that
-- link. `fpd_booking.frihet_id` is a foreign key to `fpd_frihetsberovande`,
-- UNIQUE so a chain is booked at most once, and RESTRICT so a booking record
-- can never be orphaned by deleting the chain it documents -- the same
-- reasoning `fk_fpd_atal_fu` gives in 0016.
--
-- The mugshot and ten-print capture are not built here (they need the booking
-- terminal and the camera, per 0010's own header) -- only the two facts 7.9
-- asks M6 for: which cell somebody was put in, and what was taken from them.
--
--
-- =============================================================================
-- WHY THIS IS A SEPARATE TABLE AND NOT MORE COLUMNS ON `fpd_frihetsberovande`
-- =============================================================================
--
-- The chain records a legal decision (RB 24:7/24:6/24:13) made by an officer,
-- a prosecutor or a court, at the moment each of those people made it, and
-- 0010's own header explains at length why its stage columns are written once
-- and never updated. Booking is a different kind of fact entirely: a
-- custodial administrative act (who is physically holding this person and
-- where, and what is in the property room for them) that can be corrected --
-- a cell reassignment, an inventory addition -- without that correction
-- touching a single statutory clock. Folding it into `fpd_frihetsberovande`
-- would mean either giving that table a second, looser writability rule for
-- some of its columns, or leaving `cell` and the property list as an
-- unenforced convention bolted onto a record whose whole design is that
-- nothing about it moves quietly.
--
-- One booking per chain (`uq_fpd_booking_frihet`): a person is gripen once
-- and released once per chain (0010's header again -- a re-arrest is a new
-- chain with its own number), so there is exactly one cell assignment and one
-- property inventory to record against it.
--
--
-- =============================================================================
-- RELEASE REASON, AND WHY IT IS A LOCALE KEY
-- =============================================================================
--
-- `release_reason_key` is checked server-side against `Booking.isReleaseReason`
-- before it is ever written (`booking/service.lua`) -- the same closed-list
-- discipline `Court.isBeslutGrund` and `Personnel.isDisciplineCategory` use,
-- for the reason their own modules give: the NUI renders it with `t()`, and a
-- free string accepted here would print verbatim through `t()` in both
-- locales the day it did not match a key (invariant 6, the exact defect four
-- other modules had before this one was reviewed).
--
-- `item_label` on `fpd_booking_property`, by contrast, is deliberately free
-- text and is never passed to `t()` anywhere -- it is an officer's own
-- inventory note ("black leather wallet, $40 cash", "iPhone, cracked screen"),
-- not a value drawn from a closed list, and there is no finite catalogue of
-- what a person might be carrying.

-- -----------------------------------------------------------------------------
-- The booking
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_booking` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `number`      VARCHAR(32)     NOT NULL COMMENT 'Counter kind `booking` (Appendix D): B{YY}-{#####}',

    `frihet_id`   BIGINT UNSIGNED NOT NULL COMMENT 'The gripande/häktning chain this booking is for',
    `person_id`   BIGINT UNSIGNED NOT NULL,

    `cell`        VARCHAR(32)     NULL,

    `booked_at`   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `booked_by`   VARCHAR(32)     NOT NULL COMMENT 'Discord id of the booking officer',

    -- Release from custody. Not the same fact as `fpd_frihetsberovande.frigiven_at`
    -- -- that column is when the chain's decision-maker (officer, åklagare,
    -- domare or the automatic RB 24:13 outcome) ended the frihetsberövande;
    -- this one is when the arrest terminal actually let this person out the
    -- door, cell vacated and property returned. The two are ordinarily close
    -- together and are never the same write.
    `released_at` DATETIME(3)     NULL,
    `released_by` VARCHAR(32)     NULL,
    `release_reason_key` VARCHAR(64) NULL COMMENT 'Locale key, checked against Booking.isReleaseReason',

    `classification` VARCHAR(16)  NOT NULL DEFAULT 'internal',
    `version`     INT UNSIGNED    NOT NULL DEFAULT 1,
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_booking_number` (`agency_id`, `number`),
    -- One booking per chain (see header).
    UNIQUE KEY `uq_fpd_booking_frihet` (`frihet_id`),
    KEY `idx_fpd_booking_person` (`person_id`),
    KEY `idx_fpd_booking_agency` (`agency_id`, `booked_at`),
    CONSTRAINT `fk_fpd_booking_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    -- RESTRICT: a booking record must never be orphaned by deleting the chain
    -- it documents (there is no delete path on `fpd_frihetsberovande` at all,
    -- per 0010's own header, but the constraint says so rather than assuming
    -- it).
    CONSTRAINT `fk_fpd_booking_frihet` FOREIGN KEY (`frihet_id`)
        REFERENCES `fpd_frihetsberovande` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_fpd_booking_person` FOREIGN KEY (`person_id`)
        REFERENCES `fpd_persons` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `ck_fpd_booking_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret')),
    CONSTRAINT `ck_fpd_booking_number` CHECK (CHAR_LENGTH(TRIM(`number`)) > 0),
    -- Paired: a release is recorded as one unit or not at all, the same shape
    -- `ck_fpd_atal_disposition_decided` (0016) and `ck_fpd_cert_revoked`
    -- (0017) both use.
    CONSTRAINT `ck_fpd_booking_released` CHECK (
        (`released_at` IS NULL AND `released_by` IS NULL AND `release_reason_key` IS NULL)
        OR (`released_at` IS NOT NULL AND `released_by` IS NOT NULL AND `release_reason_key` IS NOT NULL))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- The property inventory
--
-- `agency_id` is denormalized onto this table rather than left to a join
-- through `fpd_booking`, so every write here -- in particular
-- `Repo.releaseProperty` -- is scoped by a direct `WHERE id = ? AND
-- agency_id = ? AND booking_id = ?` the way this codebase generally prefers
-- (spec 3.4's parameterized-and-scoped rule, read literally) rather than a
-- write that trusts a join to enforce the boundary.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_booking_property` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `booking_id`  BIGINT UNSIGNED NOT NULL,

    `item_label`  VARCHAR(191)    NOT NULL COMMENT 'Free text -- an officer''s own inventory note, never rendered through t() (invariant 6)',
    `quantity`    SMALLINT UNSIGNED NOT NULL DEFAULT 1,

    `logged_at`   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `logged_by`   VARCHAR(32)     NOT NULL COMMENT 'Discord id of the officer who logged it',

    `released_at` DATETIME(3)     NULL,
    `released_by` VARCHAR(32)     NULL,

    PRIMARY KEY (`id`),
    KEY `idx_fpd_booking_property_booking` (`booking_id`, `released_at`),
    CONSTRAINT `fk_fpd_booking_property_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_booking_property_booking` FOREIGN KEY (`booking_id`)
        REFERENCES `fpd_booking` (`id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_booking_property_label` CHECK (CHAR_LENGTH(TRIM(`item_label`)) > 0),
    CONSTRAINT `ck_fpd_booking_property_quantity` CHECK (`quantity` >= 1),
    -- Paired, the same shape `ck_fpd_booking_released` above uses.
    CONSTRAINT `ck_fpd_booking_property_released` CHECK (
        (`released_at` IS NULL AND `released_by` IS NULL)
        OR (`released_at` IS NOT NULL AND `released_by` IS NOT NULL))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- ============================================================
-- 0019_ordningsbot.sql
-- ============================================================
-- 0019_ordningsbot.sql
--
-- Ordningsbot: on-the-spot fixed-penalty citations, against a versioned
-- tariff (spec 7.11; milestone M6).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
--
-- =============================================================================
-- THE TARIFF IS A CATALOGUE, THE SAME SHAPE AS `fpd_brott` (0008)
-- =============================================================================
--
-- A citation issued under this year's parking fine must still read, next
-- year, as the amount it was actually issued under -- the identical argument
-- 0008's header makes for the straffskala. So `fpd_ordningsbot_tariff` is
-- versioned the same way: `code` (e.g. `parking`, `noise`, `littering`) is
-- the offence across time, a row is immutable once a citation cites it, and
-- an amount change is `retire` plus `insert`, never an UPDATE.
--
-- `current_marker` is the identical trick 0008 uses for `fpd_brott` (and 0005
-- for a person's primary photo): MariaDB has no partial unique index, so
-- "at most one current version per (agency, code)" is enforced by a generated
-- column that is `code` on a live row and NULL on a retired one -- NULLs do
-- not collide in a unique index, so any number of retired versions may exist
-- while at most one is current. This is a real database constraint, not a
-- rule the service layer merely promises to keep; `Repo.setTariff` still
-- retires before it inserts, in one transaction, because the unique index
-- allows exactly one live version per code and the insert would collide with
-- the row it is replacing if it ran first (`brott/repo.lua`'s
-- `Repo.createVersion` makes the same argument, in the same order).
--
--
-- =============================================================================
-- WHY `amount` IS A WHOLE-UNIT INT AND NOT A DECIMAL
-- =============================================================================
--
-- Nothing else in this suite stores a money amount yet -- no minor-unit
-- (öre/cents) column, no DECIMAL, no precedent either way -- so there is
-- nothing here to stay consistent with. INT UNSIGNED, whole SEK, is chosen
-- because every fine spec 7.11 names ("500 kr", "1500 kr") is a round number
-- an officer reads off a printed citation, never a fractional one, and a
-- DECIMAL(10,2) buys precision this module has no use for. If a future
-- module needs fractional currency, that module's migration is where the
-- suite's first minor-unit column belongs -- not retrofitted here onto a
-- table that has no use for it.
--
--
-- =============================================================================
-- THE CITATION ITSELF, AND WHY VOID/PAID/CONTESTED HAVE NO WAY BACK
-- =============================================================================
--
-- `fpd_ordningsbot` is the record a citation number is allocated for. Its
-- `status` moves exactly once, from `issued` to one of `paid`, `contested` or
-- `void` (`ordningsbot/service.lua`'s `Ordningsbot.mayTransition` is the
-- single definition of which moves are legal, and every write in
-- `ordningsbot/repo.lua` guards the same transition with
-- `WHERE ... AND status = 'issued'` so the database refuses the second one
-- even if a route bug did not). A contested citation is not resolved here --
-- 7.11 says contesting sends it to court, and this migration does not invent
-- a second disposition mechanism beside the one `fpd_atal` (0016) already
-- owns. Marking `contested` only stops the fine and the points clock; what
-- happens to the contest is a court module's business, not this table's.
--
-- **Payment is a deliberate scope-narrowing**, in the same spirit 0016's
-- header explains for "request more investigation": 7.11 says fines move
-- "through the billing bridge", and no such bridge exists in this repo (the
-- payment bridges spec 3 lists are billing-adjacent connectors this
-- milestone does not build). `ordningsbot.pay` marks `paid_at`/`status`
-- directly rather than waiting on integration work with nothing here to
-- integrate against yet. A real billing bridge, when one is built, writes to
-- the same column through the same route; nothing about this shape needs to
-- change to accept it.
--
-- Person and vehicle are both nullable and the table requires at least one:
-- a citation is routinely written against a parked or fleeing vehicle with
-- no confirmed driver, and a person-only citation (a written warning with no
-- plate involved) is equally real. Neither column being enough alone is why
-- `ck_fpd_ordningsbot_subject` requires one rather than the other.

-- -----------------------------------------------------------------------------
-- The tariff (the versioned catalogue)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_ordningsbot_tariff` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,

    `code`        VARCHAR(32)     NOT NULL COMMENT 'Stable across versions, e.g. parking, noise, littering',
    `label_key`   VARCHAR(191)    NOT NULL COMMENT 'Locale key, never a literal string (invariant 6)',
    `amount`      INT UNSIGNED    NOT NULL COMMENT 'Whole SEK units -- see header',
    `version`     INT UNSIGNED    NOT NULL DEFAULT 1,

    `effective_from` DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `retired_at`  DATETIME(3)     NULL COMMENT 'NULL means this is the current version for its code',

    -- Currency, the same generated-column trick 0008 uses for `fpd_brott`.
    -- See header.
    `current_marker` VARCHAR(32)
        GENERATED ALWAYS AS (IF(`retired_at` IS NULL, `code`, NULL)) STORED,

    `created_by`  VARCHAR(32)     NULL COMMENT 'Discord id of the admin who set this version',
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_ordningsbot_tariff_version` (`agency_id`, `code`, `version`),
    UNIQUE KEY `uq_fpd_ordningsbot_tariff_current` (`agency_id`, `current_marker`),
    UNIQUE KEY `uq_fpd_ordningsbot_tariff_id_agency` (`id`, `agency_id`),
    KEY `idx_fpd_ordningsbot_tariff_code` (`agency_id`, `code`),
    CONSTRAINT `fk_fpd_ordningsbot_tariff_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_ordningsbot_tariff_code` CHECK (CHAR_LENGTH(TRIM(`code`)) > 0),
    CONSTRAINT `ck_fpd_ordningsbot_tariff_label` CHECK (CHAR_LENGTH(TRIM(`label_key`)) > 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- The citation
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_ordningsbot` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `number`      VARCHAR(32)     NOT NULL COMMENT 'Counter kind `citation` (Appendix D): {AGENCY}-T{YY}-{######}',

    `tariff_id`   BIGINT UNSIGNED NOT NULL COMMENT 'One immutable tariff version -- never "the current tariff"',

    `person_id`   BIGINT UNSIGNED NULL COMMENT 'Nullable -- a citation may be issued against a vehicle alone',
    `vehicle_id`  BIGINT UNSIGNED NULL,

    `issued_by`   VARCHAR(32)     NOT NULL COMMENT 'Discord id',
    `issued_at`   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    `status`      VARCHAR(16)     NOT NULL DEFAULT 'issued',

    -- Set together, once, on a void. See header for why there is no way back
    -- from any of the three terminal statuses.
    `void_reason_key` VARCHAR(64) NULL COMMENT 'Locale key',
    `voided_by`   VARCHAR(32)     NULL,
    `voided_at`   DATETIME(3)     NULL,

    `paid_at`     DATETIME(3)     NULL,
    `contested_at` DATETIME(3)    NULL,

    `classification` VARCHAR(16)  NOT NULL DEFAULT 'internal',
    `version`     INT UNSIGNED    NOT NULL DEFAULT 1,
    `updated_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_ordningsbot_number` (`agency_id`, `number`),
    UNIQUE KEY `uq_fpd_ordningsbot_id_agency` (`id`, `agency_id`),
    KEY `idx_fpd_ordningsbot_agency_issued` (`agency_id`, `issued_at`),
    KEY `idx_fpd_ordningsbot_agency_status` (`agency_id`, `status`),
    KEY `idx_fpd_ordningsbot_person` (`person_id`),
    KEY `idx_fpd_ordningsbot_vehicle` (`vehicle_id`),
    CONSTRAINT `fk_fpd_ordningsbot_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    -- RESTRICT, not CASCADE: a tariff version a citation cites must never be
    -- removable out from under it (the same reasoning `fk_fpd_atal_brott_brott`
    -- gives for a charge's catalogue row).
    CONSTRAINT `fk_fpd_ordningsbot_tariff` FOREIGN KEY (`tariff_id`)
        REFERENCES `fpd_ordningsbot_tariff` (`id`) ON DELETE RESTRICT,
    -- Composite, agency-checked FKs, the same shape `fpd_vehicle_plates` uses:
    -- a citation cannot drift into naming another agency's person or vehicle.
    -- Nullable columns in a multi-column FK are simply not checked while
    -- either half is NULL, which is exactly what a citation naming only a
    -- vehicle (or only a person) needs.
    CONSTRAINT `fk_fpd_ordningsbot_person` FOREIGN KEY (`person_id`, `agency_id`)
        REFERENCES `fpd_persons` (`id`, `agency_id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_fpd_ordningsbot_vehicle` FOREIGN KEY (`vehicle_id`, `agency_id`)
        REFERENCES `fpd_vehicles` (`id`, `agency_id`) ON DELETE RESTRICT,
    CONSTRAINT `ck_fpd_ordningsbot_status` CHECK (`status` IN
        ('issued', 'paid', 'contested', 'void')),
    CONSTRAINT `ck_fpd_ordningsbot_void` CHECK (
        (`void_reason_key` IS NULL AND `voided_by` IS NULL AND `voided_at` IS NULL)
        OR (`void_reason_key` IS NOT NULL AND `voided_by` IS NOT NULL AND `voided_at` IS NOT NULL)),
    CONSTRAINT `ck_fpd_ordningsbot_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret')),
    CONSTRAINT `ck_fpd_ordningsbot_subject` CHECK (
        `person_id` IS NOT NULL OR `vehicle_id` IS NOT NULL),
    CONSTRAINT `ck_fpd_ordningsbot_number` CHECK (CHAR_LENGTH(TRIM(`number`)) > 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- ============================================================
-- 0020_impound.sql
-- ============================================================
-- 0020_impound.sql
--
-- Vehicle impound (spec 7.15; milestone M6): the fee clock, release gated on
-- payment plus, for an investigative or evidence hold, an investigator's
-- authorization. Fires `fredpd:vehicleImpounded` on creation, which
-- `spaning/events.lua` has been listening for since 0012 -- see that file's
-- own header.
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
--
-- =============================================================================
-- WHY `vehicle_id` IS NULLABLE, AND `plate` IS NOT
-- =============================================================================
--
-- An impound is written the moment a vehicle is taken in, from whatever the
-- officer can read off the plate -- and not every plate resolves to a
-- `fpd_vehicles` row. An out-of-state plate, a vehicle never entered into this
-- server's registry, or a plate typo'd past what `Repo.byPlate` can match, are
-- all still real impounds with a real fee clock. So `plate` is captured
-- directly and unconditionally, and `vehicle_id` is filled in only when
-- `repo.create` finds a matching registry row -- the same "best effort,
-- nullable" shape `fpd_vehicles.owner_person_id` already uses for a keeper the
-- registry cannot always identify.
--
-- `ON DELETE SET NULL`: a vehicle purged from the registry does not take the
-- fee history of every impound it was ever party to with it.
--
--
-- =============================================================================
-- THE HOLD REASON, THE AUTHORIZATION, AND WHY THEY ARE PAIRED
-- =============================================================================
--
-- `held_reason_key` is a closed allowlist (`Impound.isHeldReason`), not free
-- text: the NUI renders it with `t()` the same as every other reason key in
-- this suite (`Tvang.isTvangGrund`, `Court.isBeslutGrund`), and a sentence
-- typed into a key field is the defect that review has now caught in four
-- other modules.
--
-- Only `investigative` and `evidence` need an investigator's sign-off before
-- release (`Impound.needsAuthorization`) -- a car towed for expired tags or
-- left abandoned does not wait on anybody but its fee. `hold_authorized_by`/
-- `hold_authorized_at` are consequently paired and both nullable, the same
-- `ck_fpd_atal_disposition_decided` idiom 0016 uses: an authorization has an
-- author and a moment, or it has neither.
--
--
-- =============================================================================
-- THE FEE: WHOLE CURRENCY UNITS, MINIMUM ONE DAY
-- =============================================================================
--
-- No monetary column anywhere else in this schema sets a precedent for cents
-- or a fractional unit, so `fee_per_day` is a whole-number amount in the
-- server's own currency, as ESX itself stores money. `Impound.feeOwed`
-- (`server/modules/impound/service.lua`) is the arithmetic; this column is
-- only the rate. A released-same-day vehicle still owes one day's fee -- a
-- fraction of a day held is not a fraction of a day's storage cost to the
-- department -- which is why the service rounds every partial day up rather
-- than down, with a floor of one day even at zero elapsed time.

CREATE TABLE IF NOT EXISTS `fpd_impound` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `number`      VARCHAR(32)     NOT NULL COMMENT 'Counter kind `impound` (Appendix D): I{YY}-{#####}',

    `vehicle_id`  BIGINT UNSIGNED NULL COMMENT 'NULL when the plate does not resolve to a registry row',
    `plate`       VARCHAR(16)     NOT NULL COMMENT 'Captured directly, independent of vehicle_id',
    `model`       VARCHAR(191)    NULL,

    `held_reason_key` VARCHAR(64) NOT NULL COMMENT 'Locale key: investigative | evidence | abandoned | dui | unregistered | other',
    `hold_authorized_by` VARCHAR(32) NULL COMMENT 'Discord id of the investigator, investigative/evidence hold only',
    `hold_authorized_at` DATETIME(3) NULL,

    `fee_per_day` INT UNSIGNED    NOT NULL DEFAULT 0 COMMENT 'Whole currency units per day held',

    `impounded_at` DATETIME(3)    NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `impounded_by` VARCHAR(32)    NOT NULL COMMENT 'Discord id',

    `released_at` DATETIME(3)     NULL,
    `released_by` VARCHAR(32)     NULL,
    `fee_paid`    TINYINT(1)      NOT NULL DEFAULT 0,

    `classification` VARCHAR(16) NOT NULL DEFAULT 'internal',
    `version`     INT UNSIGNED    NOT NULL DEFAULT 1,

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_impound_number` (`agency_id`, `number`),
    -- "What is currently held" -- the screen's default list.
    KEY `idx_fpd_impound_agency_held` (`agency_id`, `released_at`),
    -- The plate lookup `Repo.byPlate` runs: the most recent open record for a
    -- given plate.
    KEY `idx_fpd_impound_agency_plate` (`agency_id`, `plate`),
    CONSTRAINT `fk_fpd_impound_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_impound_vehicle` FOREIGN KEY (`vehicle_id`)
        REFERENCES `fpd_vehicles` (`id`) ON DELETE SET NULL,
    CONSTRAINT `ck_fpd_impound_reason` CHECK (`held_reason_key` IN
        ('investigative', 'evidence', 'abandoned', 'dui', 'unregistered', 'other')),
    CONSTRAINT `ck_fpd_impound_authorized` CHECK (
        (`hold_authorized_by` IS NULL AND `hold_authorized_at` IS NULL)
        OR (`hold_authorized_by` IS NOT NULL AND `hold_authorized_at` IS NOT NULL)),
    CONSTRAINT `ck_fpd_impound_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret')),
    CONSTRAINT `ck_fpd_impound_plate` CHECK (CHAR_LENGTH(TRIM(`plate`)) > 0),
    CONSTRAINT `ck_fpd_impound_number` CHECK (CHAR_LENGTH(TRIM(`number`)) > 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- ============================================================
-- 0021_gateway_outbox.sql
-- ============================================================
-- 0021_gateway_outbox.sql
--
-- The gateway bridge's outbox (spec 3.7, C4). Not scoped by agency: the
-- gateway is one process per server, not per agency, and a retry queue that
-- also had to carry an agency id would be a fact this table does not need in
-- order to resend a request.
--
-- Invariant 8: append-only. Never edit this file once it has shipped.

CREATE TABLE IF NOT EXISTS `fpd_gateway_outbox` (
    `id`              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `kind`            VARCHAR(32)     NOT NULL COMMENT 'e.g. pdf.render',
    `payload`         JSON            NOT NULL COMMENT 'The request body, resent as-is',
    `attempts`        INT UNSIGNED    NOT NULL DEFAULT 0,
    `last_error`      VARCHAR(191)    NULL,
    `last_attempt_at` DATETIME(3)     NULL,
    `created_at`      DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    KEY `idx_fpd_gateway_outbox_created` (`created_at`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- ============================================================
-- 0022_officer_superuser.sql
-- ============================================================
-- 0022_officer_superuser.sql
--
-- A permanent superuser flag on the officer row (spec 4.3, invariant 2).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
-- `server/modules/admin/superuser.lua`'s console command originally granted
-- superuser by mapping a Discord role to the `superuser` permission group
-- (`database/seeds/0003_superuser.sql`), which is checked the same way every
-- other grant is: against a live Discord role snapshot. That is right for an
-- ordinary grant and wrong for a recovery path -- the whole point of
-- `fredpd_superuser` is being available the day something else is broken,
-- and "something else" includes Discord itself: no bot configured yet on a
-- development server, a token that has expired, or a guild the server can no
-- longer reach. A recovery grant that depends on the thing most likely to be
-- broken is not a recovery grant.
--
-- This column is what makes it independent of that: a flag `Session.open`
-- reads once per session open and honours directly, in place of deriving
-- permissions from Discord roles at all. Set from the console, it survives a
-- Discord outage, a revoked role, and a `fpd_discord_members` table that has
-- never been populated because no bot has ever run against this server.

ALTER TABLE `fpd_officers`
    ADD COLUMN IF NOT EXISTS `superuser` TINYINT(1) NOT NULL DEFAULT 0
        COMMENT 'Permanent recovery grant from fredpd_superuser (console only). Independent of Discord.';

-- ============================================================
-- 0023_intel_case_number.sql
-- ============================================================
-- 0023_intel_case_number.sql
--
-- A generated number for an intelligence case (Appendix D, spec 10).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
-- Every other case-like record in the suite already draws a number from
-- `fpd_counters` under the row lock `server/core/counters.lua` describes --
-- a förundersökning is `{AGENCY}-C{YY}-{#####}` (counter kind `case`), a
-- report is `{AGENCY}-{YY}-{######}` (kind `report`). `fpd_intel_cases` was
-- the one exception: an analyst's working case file, identified only by its
-- auto-increment `id`, because Appendix D's `case` row already names the FU
-- and reusing that kind here would put two different records' numbers in one
-- sequence -- unreadable back to either.
--
-- This is its own counter kind, `intel_case`, so the format is `{AGENCY}-IC{YY}-{#####}`
-- (e.g. `LSPD-IC26-00007`) -- distinct from the FU's `-C` on sight, the same
-- way a citation's `-T` and impound's bare `I` stay apart from everything
-- else in Appendix D.
--
-- Nullable rather than backfilled: a case opened before this migration has no
-- number to allocate one from, and fabricating one out of the row's `id`
-- would be a number nobody actually drew under the counter lock. It reads as
-- "no number assigned" until an administrator's tooling gives it one, or
-- forever, if none ever does -- both are honest, and neither is a guess.

ALTER TABLE `fpd_intel_cases`
    ADD COLUMN IF NOT EXISTS `number` VARCHAR(24) NULL
        COMMENT 'Counter kind intel_case: {AGENCY}-IC{YY}-{#####}. NULL on a case opened before this column existed.',
    ADD UNIQUE KEY IF NOT EXISTS `uq_fpd_intel_cases_number` (`agency_id`, `number`);

-- ============================================================
-- 0024_ordningsbot_due.sql
-- ============================================================
-- 0024_ordningsbot_due.sql
--
-- A payment due date on a citation, and the overdue state read off it
-- (spec 7.11).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
-- 0019 gave a citation exactly four states -- issued, paid, contested, void
-- -- and left "has anyone actually paid this yet" to be read off `status`
-- alone. That collapses two different facts into one: an `issued` citation
-- from an hour ago and one from three months ago render identically, with
-- nothing on the record saying the second one is overdue. `due_at` is what
-- lets `ordningsbot/service.lua` tell them apart -- the same "computed from
-- dates, not timers" approach `impound/service.lua`'s `Impound.feeOwed`
-- already takes for the impound fee, applied here to a status instead of a
-- fee. There is still no fifth database status: `overdue` is derived at read
-- time from `status` and `due_at` together, never written to the column --
-- `ck_fpd_ordningsbot_status` is untouched by this migration, and
-- `Ordningsbot.mayTransition` still only knows the four it always has.
--
-- Written once, at issue time, from `config.server.ordningsbot.paymentWindowDays`
-- as it stood *then* -- never re-derived from whatever the config says today.
-- A later change to the payment window must not silently move the deadline on
-- a citation already handed to somebody, which is the identical argument
-- 0019's own header makes for citing an immutable tariff version rather than
-- "the current tariff".
--
-- Backfilled below for citations issued before this column existed, using the
-- same 30-day default the config ships with -- the closest honest answer
-- available, since no earlier row recorded what window was actually in effect
-- when it was issued.

ALTER TABLE `fpd_ordningsbot`
    ADD COLUMN IF NOT EXISTS `due_at` DATETIME(3) NULL
        COMMENT 'issued_at + the payment window in effect at issue time (config.server.ordningsbot.paymentWindowDays)';

UPDATE `fpd_ordningsbot`
   SET `due_at` = DATE_ADD(`issued_at`, INTERVAL 30 DAY)
 WHERE `due_at` IS NULL;

ALTER TABLE `fpd_ordningsbot`
    MODIFY COLUMN `due_at` DATETIME(3) NOT NULL;

-- ============================================================
-- 0025_intel_master_link.sql
-- ============================================================
-- 0025_intel_master_link.sql
--
-- Enforces "at most one intelligence subject per master person record" on
-- `fpd_intel_persons.master_person_id` (spec 10; milestone M2's own header on
-- that column: "master name index record, once M2 exists" -- M2 exists now).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
-- The column has carried no constraint and no code has ever written to it
-- since 0001 -- an analyst's working file and a confirmed identity in the
-- master index were two registers with a bridge nobody had built. This is
-- the write path's other half, spent on `spaning`'s known-associates read
-- (0025 also touches `server/modules/spaning/routes.lua`, not just SQL): a
-- lookout naming a master person now resolves to the analyst's associates
-- for that same person, when one has been linked.
--
-- `NULL` is unaffected by a unique index -- MariaDB does not compare NULLs
-- against each other -- so any number of subjects with no master link yet
-- may coexist; only two subjects claiming the *same* master person collide,
-- which is the one shape `Repo.byMasterPersonId` cannot answer "the" subject
-- for.

ALTER TABLE `fpd_intel_persons`
    ADD UNIQUE KEY IF NOT EXISTS `uq_fpd_intel_persons_master` (`master_person_id`);

-- ============================================================
-- 0026_personnel_loadout.sql
-- ============================================================
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

-- ============================================================
-- 0027_personnel_issue_gate.sql
-- ============================================================
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

-- ============================================================
-- 0028_person_pending_identity.sql
-- ============================================================
-- 0028_person_pending_identity.sql
--
-- Who an unidentified arrestee actually is, held where nobody can read it
-- (spec 7.2.1, 8.8).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
--
-- =============================================================================
-- WHY
-- =============================================================================
--
-- An officer can arrest somebody who refuses to show ID on the ground
-- `identitet_oklar` (`field.person.unidentified`). They become a person with
-- no name and no identifier, and the ten-print at booking is what says who
-- they are.
--
-- The ten-print reads the identifier of whoever stands at the terminal. Without
-- this table nothing tied that ped to the arrest: an officer could print a
-- bystander against an open booking and learn who *they* are, or bind the
-- bystander's identity onto the arrestee's record. So the arrest records, out
-- of sight, which character was arrested, and the capture refuses any other.
--
-- Hidden truth in the sense of 8.1: never selected by a read that reaches a
-- client, never returned, never audited by value. It exists only to be
-- compared against, and the row goes when the person is identified.

CREATE TABLE IF NOT EXISTS `fpd_person_pending_identity` (
    `person_id`   BIGINT UNSIGNED NOT NULL,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `identifier`  VARCHAR(191)    NOT NULL COMMENT 'ESX character identifier of the arrested ped. Hidden truth.',
    `created_by`  VARCHAR(32)     NOT NULL COMMENT 'Discord id of the arresting officer',
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`person_id`),
    CONSTRAINT `fk_fpd_person_pending_identity_person` FOREIGN KEY (`person_id`)
        REFERENCES `fpd_persons` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_person_pending_identity_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- ============================================================
-- 0029_call_source_officer.sql
-- ============================================================
-- 0029_call_source_officer.sql
--
-- Lets a call be raised by the officer who is standing at it (spec 7.16,
-- `call.self_initiate`): a traffic stop or something seen on patrol, without
-- the dispatch console.
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
-- `ck_fpd_calls_source` (0007) is widened by one value, `officer`. The server
-- decides the source; no route accepts it. Dropped and re-added under the
-- same name, because MariaDB cannot alter a CHECK in place.

ALTER TABLE `fpd_calls` DROP CONSTRAINT IF EXISTS `ck_fpd_calls_source`;

ALTER TABLE `fpd_calls`
    ADD CONSTRAINT `ck_fpd_calls_source` CHECK (`source` IN
        ('dispatcher', 'phone', 'export', 'panic', 'alpr', 'officer'));

-- ============================================================
-- 0030_lab_candidates.sql
-- ============================================================
-- 0030_lab_candidates.sql
--
-- Who a fingerprint search pointed at (spec 8.1.3, 8.7, 8.8).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
-- A print comparison or index search that hits a reference used to answer
-- `candidate_match` and nothing else: a lead that named nobody, so the
-- investigation it was run for could not follow it anywhere. This records
-- which person in the master index the matching reference belongs to --
-- resolved inside the database from `fpd_forensic_index.identifier` to
-- `fpd_persons.identifier`, so no profile and no identifier is ever read
-- into the application to do it.
--
-- It is a lead, not an identification (8.1.3): the screen says so, and
-- confirming it still takes a fresh reference sample. A reader sees a
-- candidate only if they may read that person's record and the case.
--
-- It also adds `fpd_lab_analyses.completed_by`. Any analyst may now finish
-- work whose clock has run out, not only the one who started it, so who
-- signed the result is a fact of its own: `assigned_to` is who took the work
-- on, `completed_by` who wrote it up (`system` for the automatic lab).

CREATE TABLE IF NOT EXISTS `fpd_lab_candidates` (
    `analysis_id` BIGINT UNSIGNED NOT NULL,
    `person_id`   BIGINT UNSIGNED NOT NULL,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`analysis_id`, `person_id`),
    KEY `idx_fpd_lab_candidates_person` (`agency_id`, `person_id`),
    CONSTRAINT `fk_fpd_lab_candidates_analysis` FOREIGN KEY (`analysis_id`)
        REFERENCES `fpd_lab_analyses` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_lab_candidates_person` FOREIGN KEY (`person_id`)
        REFERENCES `fpd_persons` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_lab_candidates_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

ALTER TABLE `fpd_lab_analyses`
    ADD COLUMN IF NOT EXISTS `completed_by` VARCHAR(32) NULL
        COMMENT 'Discord id of whoever signed the result, or system' AFTER `completed_at`;

-- ============================================================
-- seed: 0001_permissions.sql
-- ============================================================
-- Default permission groups (spec 4.3, Appendix B and C).
--
-- Seeds ship with the product and must be re-runnable without duplicating rows,
-- so every statement here is an upsert or an INSERT IGNORE.
--
-- These are the *bundles*. Which Discord role grants which bundle is not seeded:
-- role ids are specific to your guild, and that mapping is edited in the MDT
-- (spec 7.30). A fresh install therefore grants nobody anything until an
-- administrator maps the first role, which is the correct default -- and it is
-- also why a group you do not want is harmless: an unmapped group grants
-- nobody anything.
--
-- Groups here cover what exists today (M1, the records and forensics work of
-- M2 and M3, the intelligence register, and M4 dispatch). Later milestones add
-- their own. No new *group* was needed for dispatch: Appendix C already maps
-- the Dispatcher role to `dispatch`, and the officer half of CAD belongs to the
-- patrol groups that already exist.

-- -----------------------------------------------------------------------------
-- Platform groups
-- -----------------------------------------------------------------------------

INSERT INTO `fpd_permission_groups` (`key`, `name`, `inherits`, `description`) VALUES
    ('patrol_basic', 'Patrol (trainee)', NULL,
     'A trainee: read the MDT and use the internal channel, nothing that changes a record.'),
    ('patrol',       'Patrol',           'patrol_basic',
     'A patrol officer: motor pool, queries, the internal channel.'),
    ('supervisor',   'Supervisor',       'patrol',
     'A field supervisor: everything patrol has, plus oversight.'),
    ('command',      'Command',          'supervisor',
     'Command staff.'),
    -- `dispatch` is a ROOT GROUP, and the NULL is load-bearing. It used to
    -- inherit `patrol_basic`, which meant every dispatcher held
    -- `cad.unit.status` -- the key `cad/events.lua` reads to decide who belongs
    -- on the unit board. The file compensated with a negative test (hold
    -- `cad.console.open` and you are disqualified), and that is the arrangement
    -- this row exists to be rid of: a grantable capability whose only effect
    -- anywhere was to take its holder off the board, and a union of roles that
    -- could never describe somebody who both dispatches and patrols. Now the
    -- split is the absence of a key rather than the presence of one. A
    -- dispatcher is not on the board because nothing grants them
    -- `cad.unit.status`; somebody holding the Dispatcher *and* Patrol roles
    -- gets it from the patrol half and is on the board, which is correct,
    -- because they really do patrol.
    --
    -- The four keys `dispatch` actually used from `patrol_basic` are granted
    -- to it directly below. The two it did not -- `cad.unit.status` and
    -- `cad.emergency` -- are the two that were unusable anyway: both handlers
    -- read the caller's `fpd_units` row and a console operator has none.
    --
    -- Re-running this seed on a server that ran the old one flips the edge:
    -- the statement's `inherits` = VALUES(`inherits`) below is an update, not
    -- an insert-only. That is deliberate, and it is the only part of this
    -- change that is not additive.
    ('dispatch',     'Dispatch',         NULL,
     'A dispatcher: the CAD console, the registers and the internal channel. Not a unit on the board.'),
    ('admin',        'FredPD administration', NULL,
     'Configures FredPD. Deliberately does NOT inherit patrol: administering the system is not the same as being cleared to read records.')
ON DUPLICATE KEY UPDATE
    -- `VALUES(col)` rather than MySQL 8's `AS new` row alias: MariaDB does not
    -- implement the alias form, and the spec targets MariaDB 11.4 (spec 3.3).
    `name`        = VALUES(`name`),
    `inherits`    = VALUES(`inherits`),
    `description` = VALUES(`description`);

-- -----------------------------------------------------------------------------
-- Intelligence groups (spec 10, Appendix C)
--
-- The three mirror the RUE roles. What separates them is not how much they can
-- read -- an analyst reads the whole register -- but two specific powers:
-- seeing where protected intelligence came from, and destroying records.
--
-- A second statement rather than more rows above, because `inherits` is a
-- foreign key onto this same table: the platform groups must exist before
-- anything can inherit from them, and keeping the two sets apart makes the
-- dependency obvious.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Evidence, property and lab groups (spec 8)
--
-- Three roles rather than one, because section 8's whole point is that custody
-- passes between people who are accountable separately. The officer who
-- collects, the officer who stores and the analyst who tests are different
-- jobs, and a chain of custody where they are the same person proves nothing.
-- -----------------------------------------------------------------------------

INSERT INTO `fpd_permission_groups` (`key`, `name`, `inherits`, `description`) VALUES
    ('evidence_tech', 'Crime scene technician', NULL,
     'Creates and processes scenes, collects evidence, uses forensic tools.'),
    ('property_officer', 'Property room officer', NULL,
     'Takes evidence into the property room, moves it, checks it in and out.'),
    ('lab_analyst', 'Forensic analyst', NULL,
     'Works the lab queue and performs analyses. Cannot release a report alone.'),
    ('lab_supervisor', 'Forensic supervisor', 'lab_analyst',
     'An analyst who may also technically review another analyst''s work and release the report.')
ON DUPLICATE KEY UPDATE
    `name`        = VALUES(`name`),
    `inherits`    = VALUES(`inherits`),
    `description` = VALUES(`description`);

-- Utredare (investigator): the M3 lab work modelled it as a Discord role
-- separate from patrol, held by a dedicated forensic analyst. In practice an
-- investigating officer needs to start and read back their own analyses
-- without waiting on somebody mapped to `lab_analyst`, so this group carries
-- the same three lab grants on its own -- not inheriting `lab_analyst`,
-- because a department may map the two to different Discord roles and an
-- inheritance edge would tie their escalation checks together for no reason.
INSERT INTO `fpd_permission_groups` (`key`, `name`, `inherits`, `description`) VALUES
    ('utredare', 'Utredare', NULL,
     'An investigator: may submit, work and read the lab queue without a separate analyst role.')
ON DUPLICATE KEY UPDATE
    `name`        = VALUES(`name`),
    `inherits`    = VALUES(`inherits`),
    `description` = VALUES(`description`);

-- -----------------------------------------------------------------------------
-- DOJ groups (spec 7.9, 7.12)
--
-- The prosecutor and the court. Separate groups rather than ranks inside the
-- department, because RB gives them decisions the police cannot take: an
-- åklagare anhåller, a domare häktar, and a förundersökning passes to the
-- prosecutor once a suspect is anhållen.
--
-- Neither inherits a police group. A prosecutor is not a senior officer, and a
-- server that mapped its DOJ Discord role onto `supervisor` would be giving the
-- court the power to approve the police reports it later reads.
-- -----------------------------------------------------------------------------

INSERT INTO `fpd_permission_groups` (`key`, `name`, `inherits`, `description`) VALUES
    ('aklagare', 'Åklagare', NULL,
     'The prosecutor: leads a förundersökning, anhåller, decides on coercive measures.'),
    ('domare',   'Domare',   NULL,
     'The court: decides häktning, and the measures RB reserves to a judge.')
ON DUPLICATE KEY UPDATE
    `name`        = VALUES(`name`),
    `inherits`    = VALUES(`inherits`),
    `description` = VALUES(`description`);

INSERT INTO `fpd_permission_groups` (`key`, `name`, `inherits`, `description`) VALUES
    ('intel_analyst', 'Intelligence analyst', NULL,
     'Reads and writes the intelligence register. Cannot see protected sources and cannot delete.'),
    ('intel_handler', 'Source handler',       'intel_analyst',
     'An analyst who may also see where protected intelligence came from, and merge duplicate records.'),
    ('intel_command', 'Intelligence command', 'intel_handler',
     'A handler who may also delete records from the register.')
ON DUPLICATE KEY UPDATE
    `name`        = VALUES(`name`),
    `inherits`    = VALUES(`inherits`),
    `description` = VALUES(`description`);

-- -----------------------------------------------------------------------------
-- Group -> permission keys
-- -----------------------------------------------------------------------------

INSERT IGNORE INTO `fpd_group_permissions` (`group_key`, `permission`) VALUES
    -- A trainee can look and can talk, and that is all.
    ('patrol_basic', 'page.records'),
    ('patrol_basic', 'page.comms'),
    ('patrol_basic', 'comms.pdchat.send'),
    ('patrol_basic', 'comms.pdchat.view'),

    -- `forensics.trace.report` was granted here and is gone on purpose. M3
    -- shipped it as the key a client's sensors reported through, which made
    -- leaving evidence behind a thing only an officer could do: 8.3.4 says the
    -- owner of a print is whoever left it, and that is usually not an officer,
    -- and 8.10 says destroying it is open to every player. A permissioned
    -- report route answered `no_session` to every criminal on the server, so
    -- the two world routes became public instead (ADR-013) and the key now
    -- guards nothing. It was never in the spec either -- Appendix B lists four
    -- forensics keys and this was not one of them.
    --
    -- Dropping a grant from a seed is safe where dropping a migration is not:
    -- this file is re-runnable upserts (see the header), not schema history. A
    -- database that already ran the old seed keeps its row, because the
    -- statement this comment sits inside is an INSERT IGNORE and nothing here
    -- deletes; that row is inert, since no route asks for the key any more.

    -- Patrol adds the motor pool and the vehicle they need to do the job.
    ('patrol', 'garage.vehicle.draw'),
    ('patrol', 'garage.vehicle.return'),
    ('patrol', 'query.person.run'),
    ('patrol', 'query.vehicle.run'),

    -- The unified query (7.2). Running one is the most ordinary thing an
    -- officer does, and confirming a hot-file hit is part of the same act: a
    -- hit is a lead until somebody confirms it, so an officer who can raise one
    -- and not confirm it can only ever act on unconfirmed leads.
    ('patrol', 'query.run'),
    ('patrol', 'query.hit.confirm'),

    -- Reading somebody else's query history is the misuse investigation, not
    -- ordinary work. Your own history needs no key beyond being able to query:
    -- the route asks for `query.person.run` and requires this one the moment
    -- the question stops being about the caller.
    ('command', 'query.log.view'),

    -- The registers (spec 7.2-7.5). Reading them is ordinary patrol work: an
    -- officer who may run a plate has to be able to open what the plate
    -- returns, or the query answers a question nobody can follow up.
    ('patrol', 'rms.person.view'),
    ('patrol', 'rms.vehicle.view'),
    ('patrol', 'rms.firearm.view'),

    -- Writing to them is not. Correcting a record of a real person, registering
    -- a vehicle or changing a plate are all things a department wants to be able
    -- to point at afterwards, so they sit a rank up.
    ('supervisor', 'rms.person.edit'),
    ('supervisor', 'rms.vehicle.edit'),
    ('supervisor', 'rms.vehicle.flag'),
    ('supervisor', 'rms.firearm.edit'),

    -- A caution is a safety flag on a person -- armed, violent, officer safety.
    -- Held apart from `rms.person.edit` because setting one wrongly follows
    -- somebody through every future stop.
    ('supervisor', 'rms.person.caution.edit'),

    -- Anmälan (spec 7.7). Reading and writing one is the core of patrol work:
    -- an officer who attends an incident writes the anmälan for it, and one who
    -- cannot read them cannot follow up the incident they attended.
    ('patrol', 'rms.anmalan.view'),
    ('patrol', 'rms.anmalan.create'),

    -- Brottskatalogen (spec 7.10). Reading it is patrol work by necessity
    -- rather than by rank: an officer who cannot list the offences cannot
    -- write a charge, so the charging screen would be empty for everyone who
    -- actually attends incidents. The catalogue carries no personal data --
    -- it is the statute -- so there is nothing here that a lower rank should
    -- not see.
    ('patrol', 'rms.brott.view'),

    -- Approving an anmälan, and editing somebody else's draft. Supervisor
    -- grants, because both are oversight rather than work.
    --
    -- `rms.anmalan.approve` does **not** let its holder approve their own
    -- anmälan. That rule lives in `Anmalan.canApprove` and no permission
    -- reaches it, deliberately: the whole value of an approval step is that a
    -- second person looked, and on a small server the supervisor is also the
    -- author of half the reports. A grant that let the check be skipped is a
    -- grant that would be given to the one person who most wanted it.
    ('supervisor', 'rms.anmalan.approve'),
    ('supervisor', 'rms.anmalan.edit.any'),

    -- Förundersökningen (spec 7.8). Opening and leading an investigation is
    -- investigator work; `inv.fu.assign` is the supervisor half, and it is what
    -- lets a stalled investigation be reassigned when its ledare has left --
    -- otherwise unreachable, because every decision belongs to the ledare.
    ('patrol', 'inv.fu.view'),
    ('supervisor', 'inv.fu.open'),
    ('supervisor', 'inv.fu.lead'),
    ('command', 'inv.fu.assign'),

    -- Frihetsberövande (spec 7.9). The three decisions of RB, and they are the
    -- one place in FredPD where a permission stands for a **legal capacity**
    -- rather than for a job in the department.
    --
    -- `frihet.gripande` is patrol work: an officer may seize somebody caught in
    -- the act (RB 24:7), and that decision is theirs and provisional.
    --
    -- `frihet.anhallande` is the **åklagare's** (RB 24:6) and
    -- `frihet.haktning` is the **tingsrätt's** (RB 24:13). Neither is seeded to
    -- any police group, and that is the whole point of the separation: an
    -- officer who could anhålla would be taking the decision the prosecutor
    -- exists to take. They are seeded to their own groups, which a server maps
    -- its DOJ Discord roles onto.
    --
    -- `frihet.frigiv` goes to everybody, including plain patrol. A
    -- frihetsberövande that should end must be able to end at once -- most
    -- commonly because the prosecutor did not anhålla -- and making release
    -- wait for the right rank to be online would hold people for the
    -- convenience of the permission model.
    ('patrol', 'frihet.view'),
    ('patrol', 'frihet.gripande'),
    ('patrol', 'frihet.frigiv'),
    ('aklagare', 'frihet.view'),
    ('aklagare', 'frihet.anhallande'),
    ('aklagare', 'frihet.frigiv'),
    ('domare', 'frihet.view'),
    ('domare', 'frihet.haktning'),
    ('domare', 'frihet.frigiv'),

    -- Tvångsmedel (spec 7.12). Reading them is ordinary work -- an officer
    -- about to force a door has to be able to see what authorises it. Deciding
    -- one is the förundersökningsledare's, which on the police side means a
    -- supervisor; `tvang.decide.aklagare` and `.domare` raise the capacity, and
    -- the capacity is what decides whether a kroppsbesiktning may be ordered.
    --
    -- `tvang.verkstall` is separate from `tvang.decide` on purpose: the officer
    -- who carries a husrannsakan out is not usually the one who decided it, and
    -- a server where those were one grant could not record that they differed.
    ('patrol', 'tvang.view'),
    ('patrol', 'tvang.verkstall'),
    ('supervisor', 'tvang.decide'),
    ('aklagare', 'tvang.view'),
    ('aklagare', 'tvang.decide'),
    ('aklagare', 'tvang.decide.aklagare'),
    ('domare', 'tvang.view'),
    ('domare', 'tvang.decide'),
    ('domare', 'tvang.decide.domare'),

    -- Efterlysning (spec 7.13). Issuing one makes somebody turn up wanted on
    -- every query on the server, so it sits with the prosecutor and with
    -- command rather than with patrol.
    ('command', 'efterlysning.issue'),
    ('aklagare', 'efterlysning.issue'),

    -- Spaningsuppdrag (spec 7.13). Raising one is patrol work, and that is the
    -- difference between this and an efterlysning: an efterlysning is a
    -- prosecutor's decision that somebody be detained, and a spaningsuppdrag is
    -- an officer saying "look for this van". A department where the second
    -- needed command approval would simply not use it, and the sightings would
    -- stay in the radio traffic where nothing can search them.
    --
    -- What patrol cannot do is make a lookout as loud as an efterlysning:
    -- `Spaning.bannerFor` caps it, and no permission reaches that.
    ('patrol', 'spaning.view'),
    ('patrol', 'spaning.create'),

    -- Surveillance (spec 9, M5). The secret, tingsrätt-decided measures --
    -- HAK, HRA, spårsändare, kameraövervakning -- and the one place besides
    -- frihet where a permission stands for a legal capacity rather than a job.
    --
    -- `surv.request` is the åklagare's application; `surv.decide` is the
    -- domare's grant or refusal; `surv.upphav` is either's early revocation
    -- (RB 27:23). None is seeded to a police group, for the same reason
    -- `frihet.anhallande` and `frihet.haktning` are not: an officer who could
    -- request would be taking the decision the prosecutor exists to take.
    --
    -- `surv.view` is broader -- reading the register, and the base gate on
    -- observing once a measure is granted -- and it goes to command and the
    -- source handler as well as to the DOJ groups, because an intelligence
    -- unit built the case that led to the application and reads the result.
    -- `surv.log.view` is narrower again: the observer log names who listened
    -- and when, and stays with command and the DOJ groups only.
    ('aklagare', 'surv.view'),
    ('aklagare', 'surv.request'),
    ('aklagare', 'surv.upphav'),
    ('aklagare', 'surv.log.view'),
    ('aklagare', 'page.surveillance'),
    ('domare', 'surv.view'),
    ('domare', 'surv.decide'),
    ('domare', 'surv.upphav'),
    ('domare', 'surv.log.view'),
    ('domare', 'page.surveillance'),
    ('command', 'surv.view'),
    ('command', 'surv.log.view'),
    ('command', 'page.surveillance'),

    -- The per-method capability to actually observe once a measure is live
    -- (`hak.session.start`, `hak.intercept.add`). Held by the source handler,
    -- not by ordinary intelligence work: `intel_analyst` reads and writes the
    -- register, and listening to a live interception is a further step up
    -- from that, matching `intel_handler`'s own "may also see where protected
    -- intelligence came from".
    ('intel_handler', 'surv.view'),
    ('intel_handler', 'surv.phone.intercept'),
    ('intel_handler', 'surv.radio.monitor'),
    ('intel_handler', 'surv.device.deploy'),
    ('intel_handler', 'surv.device.listen'),
    ('intel_handler', 'surv.tracker.deploy'),
    ('intel_handler', 'surv.tracker.view'),
    ('intel_handler', 'page.surveillance'),

    -- Åtal och dom (spec 7.20). The charging decision is the åklagare's
    -- alone -- `court.referral.review` -- and only a domare may enter a
    -- disposition -- `court.disposition.enter`. Neither inherits the other,
    -- the same separation `frihet.anhallande` and `frihet.haktning` keep,
    -- and for the identical reason: a prosecutor who could also sentence
    -- their own charge is a prosecutor who is also the court.
    ('aklagare', 'court.referral.review'),
    ('aklagare', 'page.court'),
    ('domare', 'court.disposition.enter'),
    -- A domare has to see the docket to pick a case to dispose of, and the
    -- referral decision itself (which charges, on what ground) is exactly
    -- what a sentence has to be read against.
    ('domare', 'court.referral.review'),
    ('domare', 'page.court'),
    ('command', 'page.court'),

    -- Reading the catalogue and the two registers the prosecutor's and the
    -- court's own forms pick from: charges are chosen from the brottskatalog
    -- (ChargePicker), and a measure or a wanted notice names a person or a
    -- vehicle by searching for it (PersonPicker, VehiclePicker). Without
    -- these the forms could not be filled in at all by the people they are
    -- for. Read-only; searches are logged like everyone else's (7.2).
    ('aklagare', 'rms.brott.view'),
    ('aklagare', 'rms.person.view'),
    ('aklagare', 'rms.vehicle.view'),
    ('domare', 'rms.brott.view'),
    ('domare', 'rms.person.view'),
    ('domare', 'rms.vehicle.view'),

    -- The two field-level grants of spec 4.5. Without a group holding them the
    -- fields are not protected, they are invisible: the routes read the
    -- permission on every path that returns the field, so a department that
    -- granted nobody them would simply never see a victim's address or know a
    -- mental-health caution exists.
    --
    -- An address is ordinary supervisory work. A mental-health caution is not:
    -- an officer who cannot be told the detail cannot act on it either way, so
    -- it is held where the decision to look is a deliberate one.
    ('supervisor', 'fields.victim_address.view'),
    ('command', 'fields.mental_health.view'),

    -- A firearm trace reaches into the ballistic index and says which weapon
    -- fired what. Command only, matching `evidence.item.release` above it.
    ('command', 'rms.firearm.trace'),

    -- A supervisor sees the whole department's traffic, not just their agency's.
    ('supervisor', 'comms.pdchat.all'),

    -- Command staff read the audit log.
    ('command', 'admin.audit.view'),
    ('command', 'page.personnel'),

    -- -------------------------------------------------------------------------
    -- Dispatch, the map and ALPR (spec 7.16-7.18, M4)
    --
    -- Two audiences, not one. A dispatcher works the console; an officer works
    -- the same calls from the car. Everything the officer does there -- take a
    -- call, report progress, press the button, clear with a disposition -- is
    -- granted to `patrol` below and not to `dispatch`, because M4's acceptance
    -- criterion is a P1 run end to end and a P1 only a dispatcher can touch
    -- never leaves the console. Appendix F is the same split written as a
    -- command line: `ATT`, `ST` and `CLR` are typed by the officer.
    -- -------------------------------------------------------------------------

    -- Reading dispatch is reading. The pending queue, a call card, the unit
    -- board, the live map and the broadcast board are gated on `page.dispatch`
    -- and on nothing else, which is why it sits here rather than at `dispatch`:
    -- an officer who cannot see the queue has nothing to self-assign to, and
    -- 4.4 says the page declares what it needs and the routes enforce the same
    -- rule -- so the rail key and the read key are one key, not two.
    ('patrol_basic', 'page.dispatch'),

    -- The panic button and the officer's own status, at the lowest group there
    -- is. Both move the presser's own row and nothing else: `cad.unit.status`
    -- sets your unit's status and reports your progress on a call,
    -- `cad.emergency` raises the P1 at the position the server reads off your
    -- ped. Neither names another officer, so neither can be turned on somebody
    -- else (invariant 1).
    --
    -- This is the one place the "a trainee changes no record" line above is
    -- crossed, deliberately: an emergency call is a record, and the aspirant in
    -- the passenger seat is the person with the least experience and the most
    -- reason to press it. A panic button a trainee cannot press is a panic
    -- button that fails the only shift it was needed on.
    --
    -- `dispatch` used to inherit both and could use neither, and that inherited
    -- `cad.unit.status` is why `cad/events.lua` needed a negative marker to keep
    -- console operators off the unit board. `dispatch` inherits nothing now, so
    -- these two stop at the officer groups and the board test is a plain "holds
    -- `cad.unit.status`" -- which is also what makes this the key to think
    -- twice about granting to a non-patrol group: whoever holds it and goes on
    -- duty is a car a dispatcher can send to a robbery.
    ('patrol_basic', 'cad.unit.status'),
    ('patrol_basic', 'cad.emergency'),

    -- Patrol works calls. Self-assignment is 7.16's own word for it, clearing
    -- with a disposition is `CLR` in Appendix F, and the narrative log is where
    -- what actually happened gets written -- an officer who can attend a call
    -- but not add a line to it leaves dispatch typing up the radio by hand.
    --
    -- `cad.call.link` is held apart from `cad.call.note` because linking
    -- reaches into the registers: the handler runs the same access check
    -- `rms.person.view` would (invariant 4), and a department that wants field
    -- units narrating calls without touching the master name index can say so.
    ('patrol', 'cad.call.self_assign'),
    -- Raising your own call from the field -- a traffic stop, something seen
    -- on patrol -- without the console (7.16, `call.self_initiate`).
    ('patrol', 'cad.call.self_initiate'),
    ('patrol', 'cad.call.clear'),
    ('patrol', 'cad.call.note'),
    ('patrol', 'cad.call.link'),

    -- Plate reads (7.18). An officer whose car raised a hotlist banner has to
    -- be able to open the read behind it, or the banner is a reason to stop a
    -- car that nobody can account for afterwards. Reading the file is logged
    -- like any other query, and 11.4 is why the reads are swept at 30 days.
    ('patrol', 'alpr.read.view'),

    -- A field supervisor (Appendix A) manages units and puts out a lookout from
    -- the car, which is why neither key is pinned to the console in the
    -- schemas. `cad.unit.manage` is also the key the handler
    -- reads for 7.16's supervisor acknowledgement: an emergency call cannot be
    -- cleared without one, and the people who hold this key -- supervisor,
    -- command, dispatch -- are exactly the people who may give it. A separate
    -- `cad.emergency.ack` key would have been a fifth CAD permission that
    -- answers the same question this one already answers.
    ('supervisor', 'cad.unit.manage'),
    ('supervisor', 'cad.broadcast'),

    -- Putting a plate on the hotlist is putting a red banner in front of an
    -- officer about to stop a car, so it sits a rank up from reading one.
    ('supervisor', 'alpr.hotlist.manage'),

    -- The dispatcher. `dispatch` inherits nothing (see the group row above), so
    -- everything it holds is written out here -- starting with the four keys it
    -- used to pick up from `patrol_basic` and genuinely needs: the MDT rail
    -- entries for records and comms, and the internal channel it runs the shift
    -- on. `page.dispatch` was granted here even when it was inherited, and the
    -- reason still stands: the console is this group's whole job and it must not
    -- stop working because somebody edits an inheritance edge.
    ('dispatch', 'page.records'),
    ('dispatch', 'page.comms'),
    ('dispatch', 'comms.pdchat.send'),
    ('dispatch', 'comms.pdchat.view'),

    -- `cad.console.open` WAS HERE AND IS RETIRED. The comment that stood in its
    -- place said it was "what the dispatch console placement calls", and that
    -- described a mechanism that has never existed: a placement carries no
    -- permission at all (ADR-006, `core/placements.lua`), and the two
    -- create-and-assign routes are pinned to the placement by `accessPoint` and
    -- gated on `cad.call.create` and `cad.call.dispatch`, which are right here.
    -- Nothing read the key as a grant anywhere in the product. Its only effect
    -- was in `cad/events.lua`, which disqualified whoever held it from the unit
    -- board -- so an administrator who granted it to `supervisor` off the
    -- strength of this comment signed every field supervisor off the board and
    -- killed their panic button, and the console they were trying to open had
    -- never needed a key.
    --
    -- Dropping a grant from a seed is safe where dropping a migration is not:
    -- this file is re-runnable upserts (see the header), not schema history. A
    -- database that already ran the old seed keeps its row, because the
    -- statement this comment sits inside is an INSERT IGNORE and nothing here
    -- deletes; that row is inert, since nothing asks for the key any more. The
    -- same treatment `forensics.trace.report` got under ADR-013, for the same
    -- reason. The key is also out of Appendix B and out of the admin catalogue
    -- in `modules/admin/routes.lua`, which is what stops the group editor
    -- offering it again.
    --
    -- `cad.call.self_assign` is absent for the reason that has not changed: a
    -- dispatcher is not a unit, has no `fpd_units` row and has nowhere to be
    -- dispatched to.
    ('dispatch', 'page.dispatch'),
    ('dispatch', 'cad.call.create'),
    ('dispatch', 'cad.call.dispatch'),
    ('dispatch', 'cad.call.clear'),
    ('dispatch', 'cad.call.note'),
    ('dispatch', 'cad.call.link'),
    ('dispatch', 'cad.unit.manage'),
    ('dispatch', 'cad.broadcast'),

    -- Dispatch does not inherit `patrol`, so the two ALPR keys are granted
    -- again rather than picked up: a dispatcher checks a read against a call
    -- and is usually the person who puts a stolen plate on the list in the
    -- first place.
    ('dispatch', 'alpr.read.view'),
    ('dispatch', 'alpr.hotlist.manage'),

    -- The register reads, granted again for the same reason and for a sharper
    -- one: WITHOUT THESE TWO ROWS `cad.call.link` ABOVE IS A KEY WITH NOTHING
    -- BEHIND IT. `call.link` takes a register row id and refuses a name or a
    -- plate deliberately (7.16), so the only way to obtain one is
    -- `person.search` or `vehicle.search` -- and those are gated on these keys.
    -- A dispatcher granted `cad.call.link` and not these pressed Search on the
    -- call card, was answered `forbidden`, and could never reach the route the
    -- seed had just given them. The comment above `('patrol', 'cad.call.link')`
    -- says linking "reaches into the registers: the handler runs the same
    -- access check `rms.person.view` would"; this is the other half of that
    -- sentence written down, because a group that may link has to be able to
    -- read what it is linking.
    --
    -- `page.records` is already here through `patrol_basic`, so the rail has
    -- been opening the register for dispatchers all along and every search on
    -- it refused. These rows make the page do what the rail already advertised.
    --
    -- What they unlock is four read routes and nothing else: `person.search`,
    -- `person.get`, `vehicle.search`, `vehicle.get`. Running names and plates
    -- is the canonical dispatcher job, and every other control still applies
    -- unchanged -- `dispatch` holds `clearance.internal` and nothing above it,
    -- so a restricted record still comes back as the 4.5 stub, and the two
    -- field grants are somebody else's: `fields.victim_address.view` is
    -- `supervisor`'s and `fields.mental_health.view` is `command`'s.
    --
    -- What is deliberately NOT here: every `rms.*.edit` and `rms.vehicle.flag`
    -- (a dispatcher reads the register, they do not correct it);
    -- `rms.firearm.view`, because nothing a dispatcher does reaches the weapons
    -- register and a link is only ever to a person or a vehicle
    -- (`Repo.linkTarget` knows those two kinds and no other); and the unified
    -- query keys `query.run`, `query.person.run`, `query.vehicle.run` and
    -- `query.hit.confirm`, which stay with `patrol` -- opening a record is not
    -- the same act as running a 7.2 query, and confirming a hot-file hit is a
    -- decision for the officer standing at the car.
    ('dispatch', 'rms.person.view'),
    ('dispatch', 'rms.vehicle.view'),

    -- -------------------------------------------------------------------------
    -- Record clearance (spec 4.5, Appendix B and C)
    -- -------------------------------------------------------------------------

    -- WITHOUT THESE ROWS THE PRODUCT DOES NOT WORK AT ALL, and it fails in the
    -- least obvious way there is. `Access.clearanceOf` answers `open` for a
    -- session holding no `clearance.*` key; every record table defaults its
    -- `classification` column to `internal`; and the read rule is clearance >=
    -- classification. So on a freshly seeded server every person, vehicle,
    -- firearm and call was refused to everybody, including the officer who had
    -- just created it -- a blank screen with no error, because a refused read is
    -- deliberately indistinguishable from nothing to show (4.5).
    --
    -- `internal` is the ordinary working level: it is what an unclassified
    -- record is, so being cleared to it means "may do the job", not "is
    -- trusted with something". The levels above it are the ladder, and they
    -- follow supervision rather than seniority -- a source handler outranks a
    -- patrol supervisor here because of what they read, not where they sit.
    --
    -- Granted per group rather than to one base group everyone inherits,
    -- because half of these do not inherit from `patrol_basic` at all
    -- (`dispatch` does; `evidence_tech`, `lab_analyst`, `property_officer` and
    -- the intelligence groups are roots).
    ('patrol_basic', 'clearance.internal'),
    ('supervisor', 'clearance.restricted'),
    ('command', 'clearance.confidential'),
    ('dispatch', 'clearance.internal'),

    ('evidence_tech', 'clearance.internal'),
    ('property_officer', 'clearance.internal'),
    ('lab_analyst', 'clearance.internal'),
    ('lab_supervisor', 'clearance.restricted'),
    ('utredare', 'clearance.internal'),

    -- Intelligence reads what the rest of the department may not (spec 10), so
    -- it starts a rung higher and its command tier is the only group seeded at
    -- `secret`.
    ('intel_analyst', 'clearance.restricted'),
    ('intel_handler', 'clearance.confidential'),
    ('intel_command', 'clearance.secret'),

    -- Administration configures the system: permissions, placements, fleet.
    -- Note what is absent: no record clearance, no compartments. An admin who
    -- needs to read records is granted a records group as well, deliberately
    -- and visibly (spec 4.3, Appendix C).
    ('admin', 'page.admin'),
    ('admin', 'admin.permissions.edit'),

    -- Editing the groups themselves, not just which role gets which group.
    -- Held apart from `admin.permissions.edit` on purpose: mapping a role to an
    -- existing bundle and authoring what a bundle is worth are different
    -- powers, and a server that wants one without the other must be able to
    -- say so.
    ('admin', 'admin.groups.edit'),

    ('admin', 'admin.placement.edit'),
    ('admin', 'admin.branding.edit'),
    ('admin', 'admin.audit.view'),
    ('admin', 'garage.fleet.edit'),

    -- Editing brottskatalogen (spec 7.10). `admin` and nobody else, including
    -- not `command`: a straffskala is the legal basis every charge on every
    -- record is measured against, and an edit to one is quoted in court long
    -- after whoever made it has forgotten. The routes behind it are `sensitive`
    -- too, so a stale Discord snapshot cannot be used to reach them (4.2).
    --
    -- Editing is additive by construction -- a change writes a new version and
    -- supersedes the old one, it never rewrites a row a record cites (7.10) --
    -- so the power this grants is to change what can be charged *next*, not to
    -- alter what was charged before. That is why it is a grant at all rather
    -- than something reserved to a migration.
    ('admin', 'admin.brott.edit'),

    -- The health screen (7.30). It goes to `admin` and to nobody else, because
    -- it is the one group whose job is the running system rather than the
    -- records in it -- and because what the screen shows is totals about the
    -- server, not anything about a case: counts of sessions, how old the
    -- Discord snapshot is, and the forensics grid's counters.
    --
    -- It is granted here rather than left in the catalogue for somebody to add
    -- because the route is unreachable without a grant, and `admin.health` is
    -- what ADR-013 leans on: the public tier writes no audit row for a trace a
    -- criminal destroys, and the grid's `destroyed` counter is the only mark
    -- the act leaves anywhere. A counter behind a permission no group holds is
    -- the same as no counter at all.
    ('admin', 'admin.health.view'),

    -- The crime scene technician (8.4). Collecting is a specialist job: a
    -- patrol officer who picks a casing up off the ground has not collected
    -- evidence, they have contaminated a scene.
    --
    -- `forensics.evidence.collect` gates one route, `evidence.collect`, which
    -- is the only route that writes an evidence item. It covers both ways of
    -- securing a sample: a `traceKey` takes a trace out of the grid, and a
    -- `targetId` takes residue off a person's hands (8.2). They are the same
    -- act -- a technician securing a sample -- so they are the same grant, and
    -- there is no separate swab key: it would be a fifth forensics permission
    -- the spec does not have (Appendix B lists four) and a group nobody
    -- remembered to give it to, which is how a route ships dead.
    ('evidence_tech', 'page.evidence'),
    ('evidence_tech', 'forensics.scene.create'),
    ('evidence_tech', 'forensics.scene.release'),
    ('evidence_tech', 'forensics.evidence.collect'),
    ('evidence_tech', 'forensics.tools.use'),
    ('evidence_tech', 'evidence.item.view'),
    -- The live scanner (8.8): a separate grant from `forensics.evidence.collect`
    -- because it discloses a detained person's identity rather than collecting
    -- a sample, the same reasoning that keeps property intake and disposal
    -- apart below.
    ('evidence_tech', 'forensics.identity.scan'),

    -- The property room (8.6). Note what is separate: intake and disposal are
    -- not the same grant, because destroying evidence should be a decision
    -- somebody is named for.
    ('property_officer', 'page.evidence'),
    ('property_officer', 'evidence.item.view'),
    ('property_officer', 'evidence.item.intake'),
    ('property_officer', 'evidence.item.transfer'),
    ('property_officer', 'evidence.item.checkout'),
    ('property_officer', 'evidence.item.reseal'),
    ('property_officer', 'evidence.audit.run'),

    -- The lab (8.7).
    ('lab_analyst', 'page.lab'),
    ('lab_analyst', 'evidence.item.view'),
    ('lab_analyst', 'lab.request.create'),
    ('lab_analyst', 'lab.queue.view'),
    ('lab_analyst', 'lab.analysis.perform'),

    -- An investigator, same three lab grants as an analyst, held without the
    -- separate role (see the group definition above).
    ('utredare', 'page.lab'),
    ('utredare', 'evidence.item.view'),
    ('utredare', 'lab.request.create'),
    ('utredare', 'lab.queue.view'),
    ('utredare', 'lab.analysis.perform'),

    -- Technical review by a second analyst before release (8.7). Held apart
    -- from performing the analysis on purpose: reviewing your own work is not
    -- a review.
    ('lab_supervisor', 'lab.analysis.review'),
    ('lab_supervisor', 'lab.report.release'),

    -- Command signs off on releasing and disposing of evidence.
    ('command', 'evidence.item.view'),
    ('command', 'evidence.item.release'),
    ('command', 'evidence.item.dispose'),

    -- The analyst: the whole register, read and write.
    ('intel_analyst', 'page.intel'),
    ('intel_analyst', 'intel.module.open'),
    ('intel_analyst', 'intel.person.view'),
    ('intel_analyst', 'intel.person.edit'),
    ('intel_analyst', 'intel.org.view'),
    ('intel_analyst', 'intel.org.edit'),
    ('intel_analyst', 'intel.case.view'),
    ('intel_analyst', 'intel.case.edit'),
    ('intel_analyst', 'intel.report.view'),
    ('intel_analyst', 'intel.report.create'),
    ('intel_analyst', 'intel.report.edit'),
    ('intel_analyst', 'intel.evidence.add'),

    -- The handler. `intel.source.view` is the one that matters: without it a
    -- note from an informant, a wiretap or surveillance is readable but its
    -- source is withheld. That distinction is the whole reason the group
    -- exists -- in PD-Span every account could see every source.
    ('intel_handler', 'intel.source.view'),
    ('intel_handler', 'intel.person.merge'),

    -- Command. Deletion is separated deliberately: intelligence is meant to
    -- outlive the record it hung on, and destroying it should be a decision
    -- somebody is named for.
    ('intel_command', 'intel.record.delete');

-- -----------------------------------------------------------------------------
-- Personnel (spec 7.22-7.24, M6)
--
-- Every officer opens their own roster entry and clocks their own shift --
-- `personnel.shift.own` never takes an id, so granting it widely grants
-- nothing beyond the presser's own row (spec 7.22's own reasoning, the same
-- shape `cad.unit.status` already uses for the panic button). Editing
-- somebody else's roster row, assigning equipment and issuing certifications
-- are supervisory. The disciplinary file is IA-classified and ships stubbed
-- to everyone until an operator configures `internal_affairs` (spec 4.5), so
-- granting `personnel.discipline.view` here only decides who is *asked* --
-- the compartment decides who is *shown*.
-- -----------------------------------------------------------------------------

INSERT IGNORE INTO `fpd_group_permissions` (`group_key`, `permission`) VALUES
    ('patrol_basic', 'page.personnel'),
    ('patrol_basic', 'personnel.roster.view'),
    ('patrol_basic', 'personnel.shift.own'),

    ('supervisor', 'personnel.roster.edit'),
    ('supervisor', 'personnel.equipment.manage'),
    ('supervisor', 'personnel.certification.manage'),

    ('command', 'personnel.discipline.view'),
    ('command', 'personnel.discipline.manage');

-- -----------------------------------------------------------------------------
-- Booking (spec 7.9, M6)
--
-- Custodial administration, not a legal decision -- the same tier split
-- `frihet` uses for `gripande`/`frigiv`: visibility for everyone including a
-- trainee (`page.booking`, `booking.view` at `patrol_basic`), intake and
-- release for an ordinary officer (`booking.intake`, `booking.release` at
-- `patrol`). Neither `aklagare` nor `domare` gets anything here.
-- -----------------------------------------------------------------------------

INSERT IGNORE INTO `fpd_group_permissions` (`group_key`, `permission`) VALUES
    ('patrol_basic', 'page.booking'),
    ('patrol_basic', 'booking.view'),

    ('patrol', 'booking.intake'),
    ('patrol', 'booking.release');

-- -----------------------------------------------------------------------------
-- Vehicle impound (spec 7.15, M6)
--
-- Viewing and creating an impound is ordinary patrol work -- an officer who
-- tows a car writes the record for it, the same reasoning `rms.anmalan.create`
-- gets. Authorizing an investigative or evidence hold is the investigator-tier
-- decision spec 7.15 calls out by name; it sits with `inv.fu.lead` at
-- `supervisor` rather than with `inv.fu.assign` at `command`, because it is the
-- same "leads the investigation" capacity that already opens and leads an FU,
-- not the narrower reassignment power `command` alone holds. Release is
-- patrol work again: `Impound.mayRelease` is the real gate (fee paid, and
-- authorized when the hold needs it), so nothing is gained by also
-- restricting who may press the button once those conditions are met.
-- -----------------------------------------------------------------------------

INSERT IGNORE INTO `fpd_group_permissions` (`group_key`, `permission`) VALUES
    ('patrol_basic', 'page.impound'),
    ('patrol', 'impound.view'),
    ('patrol', 'impound.create'),
    ('patrol', 'impound.release'),
    ('supervisor', 'impound.authorize');

-- -----------------------------------------------------------------------------
-- Ordningsbot (spec 7.11, M6)
--
-- The fine schedule and citation history are visible department-wide, the
-- same tier `booking.view` gets. Issuing, marking a citation contested (intake
-- paperwork, not a disposition -- the disposition is `court.disposition.enter`
-- if it goes to court) and marking one paid (no billing bridge exists yet; see
-- 0019's header) are full-duty work at `patrol`, so the officer who wrote the
-- ticket is never stranded from its own follow-up. Voiding an already-issued
-- citation is a correction, held at `supervisor` the same way
-- `impound.authorize` holds a reversal above the tier that first acted.
-- -----------------------------------------------------------------------------

INSERT IGNORE INTO `fpd_group_permissions` (`group_key`, `permission`) VALUES
    ('patrol_basic', 'page.ordningsbot'),
    ('patrol_basic', 'ordningsbot.tariff.view'),
    ('patrol_basic', 'ordningsbot.view'),

    ('patrol', 'ordningsbot.issue'),
    ('patrol', 'ordningsbot.contest'),
    ('patrol', 'ordningsbot.pay'),

    ('supervisor', 'ordningsbot.void');

-- ============================================================
-- seed: 0002_brott.sql
-- ============================================================
-- 0002_brott.sql — the starter brottskatalog (spec 7.10).
--
-- Seeds ship with the product and must be re-runnable without duplicating
-- rows, so this is an INSERT IGNORE against `uq_fpd_brott_version`.
--
--
-- WHAT THIS IS, AND WHAT IT IS NOT
--
-- A working starting point: the offences an RP police department actually
-- charges, with the straffskala each one carries in Swedish law as it stands.
-- It is not the whole of brottsbalken, and it is not legal advice. An
-- administrator adds, versions and retires entries from the MDT under
-- `admin.brott.edit`, and 7.10's versioning rule means doing so never alters
-- a record already written against an earlier version.
--
-- **Every row is seeded for every agency**, by joining `fpd_agencies` rather
-- than naming one. A catalogue is per agency (`fpd_brott.agency_id`) because
-- a server may run departments in different jurisdictions, but the statute is
-- the same statute -- so each agency starts from the same rows and diverges
-- only if somebody edits one.
--
-- Version 1 throughout, and `superseded_at` NULL, so every row is current.
-- `created_by` is NULL: nobody authored these, the seed did.
--
--
-- ABOUT THE NUMBERS
--
-- The three penalty columns are months, and they are read together (see 0008):
--
--   boter = 1, max = 0      böter only, no fängelse at all (olovlig körning)
--   boter = 1, max = 6      "böter eller fängelse i högst sex månader"
--   boter = 0, min = 0      "fängelse i högst N"
--   boter = 0, min > 0      "fängelse i lägst M och högst N"
--   max = NULL              livstid (mord)
--
-- `preskription_years` follows BrB 35:1 from the ceiling, and is NULL for the
-- two offences BrB 35:2 exempts -- mord and dråp have not been subject to
-- preskription since 2010. It is stored rather than derived because those
-- exceptions exist: a formula would quietly give mord a twenty-five year
-- limitation period that the law removed.
--
-- `forsok` and `forberedelse` say whether attempt and preparation are
-- punishable for this offence (BrB 23). They are not a property of the
-- straffskala; they are separate statements in each kapitel, so they are
-- recorded per row rather than inferred from the ceiling.
--
-- Rubriker are locale keys (`brott.rubrik.<slug>`), never literal text
-- (invariant 6, and 5.3 for code tables). Both locale files carry every key
-- this file references, and `pnpm i18n:check` fails if one goes missing.

INSERT IGNORE INTO `fpd_brott`
    (`agency_id`, `code`, `version`, `balk`, `kapitel`, `paragraf`, `stycke`,
     `label_key`, `grad`, `boter`,
     `fangelse_min_months`, `fangelse_max_months`,
     `forsok`, `forberedelse`, `preskription_years`)
SELECT
        a.`id`, t.`code`, t.`version`, t.`balk`, t.`kapitel`, t.`paragraf`, t.`stycke`,
        t.`label_key`, t.`grad`, t.`boter`,
        t.`fangelse_min_months`, t.`fangelse_max_months`,
        t.`forsok`, t.`forberedelse`, t.`preskription_years`
    FROM `fpd_agencies` a
    CROSS JOIN (
        SELECT 'BRB-3-1' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               3 AS `kapitel`, 1 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.mord' AS `label_key`, 'normal' AS `grad`, 0 AS `boter`,
               120 AS `fangelse_min_months`, NULL AS `fangelse_max_months`,
               1 AS `forsok`, 1 AS `forberedelse`, NULL AS `preskription_years`
        UNION ALL
        SELECT 'BRB-3-2' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               3 AS `kapitel`, 2 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.drap' AS `label_key`, 'normal' AS `grad`, 0 AS `boter`,
               72 AS `fangelse_min_months`, 120 AS `fangelse_max_months`,
               1 AS `forsok`, 1 AS `forberedelse`, NULL AS `preskription_years`
        UNION ALL
        SELECT 'BRB-3-5' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               3 AS `kapitel`, 5 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.misshandel' AS `label_key`, 'normal' AS `grad`, 0 AS `boter`,
               0 AS `fangelse_min_months`, 24 AS `fangelse_max_months`,
               1 AS `forsok`, 0 AS `forberedelse`, 5 AS `preskription_years`
        UNION ALL
        SELECT 'BRB-3-5-R' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               3 AS `kapitel`, 5 AS `paragraf`, 2 AS `stycke`,
               'brott.rubrik.ringa_misshandel' AS `label_key`, 'ringa' AS `grad`, 1 AS `boter`,
               0 AS `fangelse_min_months`, 6 AS `fangelse_max_months`,
               0 AS `forsok`, 0 AS `forberedelse`, 2 AS `preskription_years`
        UNION ALL
        SELECT 'BRB-3-6' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               3 AS `kapitel`, 6 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.grov_misshandel' AS `label_key`, 'grov' AS `grad`, 0 AS `boter`,
               18 AS `fangelse_min_months`, 72 AS `fangelse_max_months`,
               1 AS `forsok`, 1 AS `forberedelse`, 10 AS `preskription_years`
        UNION ALL
        SELECT 'BRB-4-4' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               4 AS `kapitel`, 4 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.olaga_tvang' AS `label_key`, 'normal' AS `grad`, 0 AS `boter`,
               0 AS `fangelse_min_months`, 24 AS `fangelse_max_months`,
               1 AS `forsok`, 0 AS `forberedelse`, 5 AS `preskription_years`
        UNION ALL
        SELECT 'BRB-4-5' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               4 AS `kapitel`, 5 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.olaga_hot' AS `label_key`, 'normal' AS `grad`, 1 AS `boter`,
               0 AS `fangelse_min_months`, 12 AS `fangelse_max_months`,
               0 AS `forsok`, 0 AS `forberedelse`, 2 AS `preskription_years`
        UNION ALL
        SELECT 'BRB-8-1' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               8 AS `kapitel`, 1 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.stold' AS `label_key`, 'normal' AS `grad`, 0 AS `boter`,
               0 AS `fangelse_min_months`, 24 AS `fangelse_max_months`,
               1 AS `forsok`, 1 AS `forberedelse`, 5 AS `preskription_years`
        UNION ALL
        SELECT 'BRB-8-2' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               8 AS `kapitel`, 2 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.ringa_stold' AS `label_key`, 'ringa' AS `grad`, 1 AS `boter`,
               0 AS `fangelse_min_months`, 6 AS `fangelse_max_months`,
               1 AS `forsok`, 0 AS `forberedelse`, 2 AS `preskription_years`
        UNION ALL
        SELECT 'BRB-8-4' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               8 AS `kapitel`, 4 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.grov_stold' AS `label_key`, 'grov' AS `grad`, 0 AS `boter`,
               6 AS `fangelse_min_months`, 72 AS `fangelse_max_months`,
               1 AS `forsok`, 1 AS `forberedelse`, 10 AS `preskription_years`
        UNION ALL
        SELECT 'BRB-8-5' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               8 AS `kapitel`, 5 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.ran' AS `label_key`, 'normal' AS `grad`, 0 AS `boter`,
               12 AS `fangelse_min_months`, 72 AS `fangelse_max_months`,
               1 AS `forsok`, 1 AS `forberedelse`, 10 AS `preskription_years`
        UNION ALL
        SELECT 'BRB-8-6' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               8 AS `kapitel`, 6 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.grovt_ran' AS `label_key`, 'grov' AS `grad`, 0 AS `boter`,
               60 AS `fangelse_min_months`, 120 AS `fangelse_max_months`,
               1 AS `forsok`, 1 AS `forberedelse`, 15 AS `preskription_years`
        UNION ALL
        SELECT 'BRB-9-1' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               9 AS `kapitel`, 1 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.bedrageri' AS `label_key`, 'normal' AS `grad`, 0 AS `boter`,
               0 AS `fangelse_min_months`, 24 AS `fangelse_max_months`,
               1 AS `forsok`, 0 AS `forberedelse`, 5 AS `preskription_years`
        UNION ALL
        SELECT 'BRB-12-1' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               12 AS `kapitel`, 1 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.skadegorelse' AS `label_key`, 'normal' AS `grad`, 0 AS `boter`,
               0 AS `fangelse_min_months`, 24 AS `fangelse_max_months`,
               1 AS `forsok`, 0 AS `forberedelse`, 5 AS `preskription_years`
        UNION ALL
        SELECT 'BRB-17-1' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               17 AS `kapitel`, 1 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.vald_mot_tjansteman' AS `label_key`, 'normal' AS `grad`, 0 AS `boter`,
               0 AS `fangelse_min_months`, 24 AS `fangelse_max_months`,
               1 AS `forsok`, 0 AS `forberedelse`, 5 AS `preskription_years`
        UNION ALL
        SELECT 'BRB-17-1-R' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               17 AS `kapitel`, 1 AS `paragraf`, 3 AS `stycke`,
               'brott.rubrik.ringa_vald_mot_tjansteman' AS `label_key`, 'ringa' AS `grad`, 1 AS `boter`,
               0 AS `fangelse_min_months`, 6 AS `fangelse_max_months`,
               0 AS `forsok`, 0 AS `forberedelse`, 2 AS `preskription_years`
        UNION ALL
        SELECT 'BRB-17-4' AS `code`, 1 AS `version`, 'BrB' AS `balk`,
               17 AS `kapitel`, 4 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.valdsamt_motstand' AS `label_key`, 'normal' AS `grad`, 1 AS `boter`,
               0 AS `fangelse_min_months`, 6 AS `fangelse_max_months`,
               0 AS `forsok`, 0 AS `forberedelse`, 2 AS `preskription_years`
        UNION ALL
        SELECT 'NSL-1' AS `code`, 1 AS `version`, 'NSL' AS `balk`,
               1 AS `kapitel`, 1 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.narkotikabrott' AS `label_key`, 'normal' AS `grad`, 0 AS `boter`,
               0 AS `fangelse_min_months`, 36 AS `fangelse_max_months`,
               1 AS `forsok`, 1 AS `forberedelse`, 10 AS `preskription_years`
        UNION ALL
        SELECT 'NSL-2' AS `code`, 1 AS `version`, 'NSL' AS `balk`,
               1 AS `kapitel`, 2 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.ringa_narkotikabrott' AS `label_key`, 'ringa' AS `grad`, 1 AS `boter`,
               0 AS `fangelse_min_months`, 6 AS `fangelse_max_months`,
               0 AS `forsok`, 0 AS `forberedelse`, 2 AS `preskription_years`
        UNION ALL
        SELECT 'NSL-3' AS `code`, 1 AS `version`, 'NSL' AS `balk`,
               1 AS `kapitel`, 3 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.grovt_narkotikabrott' AS `label_key`, 'grov' AS `grad`, 0 AS `boter`,
               24 AS `fangelse_min_months`, 84 AS `fangelse_max_months`,
               1 AS `forsok`, 1 AS `forberedelse`, 10 AS `preskription_years`
        UNION ALL
        SELECT 'TBL-3' AS `code`, 1 AS `version`, 'TBL' AS `balk`,
               1 AS `kapitel`, 3 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.olovlig_korning' AS `label_key`, 'normal' AS `grad`, 1 AS `boter`,
               0 AS `fangelse_min_months`, 0 AS `fangelse_max_months`,
               0 AS `forsok`, 0 AS `forberedelse`, 2 AS `preskription_years`
        UNION ALL
        SELECT 'TBL-4' AS `code`, 1 AS `version`, 'TBL' AS `balk`,
               1 AS `kapitel`, 4 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.rattfylleri' AS `label_key`, 'normal' AS `grad`, 1 AS `boter`,
               0 AS `fangelse_min_months`, 6 AS `fangelse_max_months`,
               0 AS `forsok`, 0 AS `forberedelse`, 2 AS `preskription_years`
        UNION ALL
        SELECT 'TBL-4A' AS `code`, 1 AS `version`, 'TBL' AS `balk`,
               1 AS `kapitel`, 4 AS `paragraf`, 2 AS `stycke`,
               'brott.rubrik.grovt_rattfylleri' AS `label_key`, 'grov' AS `grad`, 0 AS `boter`,
               0 AS `fangelse_min_months`, 24 AS `fangelse_max_months`,
               0 AS `forsok`, 0 AS `forberedelse`, 5 AS `preskription_years`
        UNION ALL
        SELECT 'VAPL-9-1' AS `code`, 1 AS `version`, 'VapL' AS `balk`,
               9 AS `kapitel`, 1 AS `paragraf`, 1 AS `stycke`,
               'brott.rubrik.vapenbrott' AS `label_key`, 'normal' AS `grad`, 0 AS `boter`,
               0 AS `fangelse_min_months`, 36 AS `fangelse_max_months`,
               1 AS `forsok`, 0 AS `forberedelse`, 10 AS `preskription_years`
        UNION ALL
        SELECT 'VAPL-9-1A' AS `code`, 1 AS `version`, 'VapL' AS `balk`,
               9 AS `kapitel`, 1 AS `paragraf`, 2 AS `stycke`,
               'brott.rubrik.grovt_vapenbrott' AS `label_key`, 'grov' AS `grad`, 0 AS `boter`,
               24 AS `fangelse_min_months`, 60 AS `fangelse_max_months`,
               1 AS `forsok`, 0 AS `forberedelse`, 10 AS `preskription_years`
    ) t;

-- ============================================================
-- seed: 0003_superuser.sql
-- ============================================================
-- 0003_superuser.sql
--
-- The superuser permission group: one group, one grant, and the grant is the
-- literal wildcard '*' -- everything, in every namespace, forever -- rather
-- than an enumerated list of every permission key that exists today.
--
-- A list would go stale. It already has, once: the group editor's own
-- `PERMISSION_CATALOGUE` (`server/modules/admin/routes.lua`) was hand-written
-- against an earlier shape of the product and is missing entire modules'
-- worth of keys real routes check today (personnel, booking, impound,
-- ordningsbot, the `page.*` keys for all four), while offering a page of keys
-- (`personnel.hire`, `rms.report.*`, ...) that nothing checks any more. A
-- migration that copied that list in would carry the same drift into
-- `superuser`, and being append-only, could never be corrected -- only ever
-- patched around in a later file. `Perms.satisfies` honouring a bare '*'
-- (spec `server/core/perms.lua`) is what lets one row stay correct without
-- ever being edited again.
--
-- This group inherits nothing and is inherited by nothing. It is not a rank
-- above `command` or `admin` -- it is a recovery tool, granted only by the
-- console command `fredpd_superuser` (`server/modules/admin/superuser.lua`),
-- which has no in-game counterpart at all. Nothing in the ordinary role map or
-- group editor can reach it on its own: mapping a role to a group the caller
-- does not already hold is refused (the same escalation guard
-- `admin.rolemap.create` and `admin.group.*` already enforce), and nobody
-- reaches `'*'` except through this seed or through already holding it.
--
-- Invariant 8: append-only. Never edit this file once it has shipped.

INSERT INTO `fpd_permission_groups` (`key`, `name`, `inherits`, `description`) VALUES
    ('superuser', 'Superuser',        NULL,
     'Every permission that exists, in every namespace. Granted only by the console command fredpd_superuser -- never through the role map or the group editor, and never inherited. A recovery tool, not a rank.')
ON DUPLICATE KEY UPDATE
    `name`        = VALUES(`name`),
    `inherits`    = VALUES(`inherits`),
    `description` = VALUES(`description`);

INSERT IGNORE INTO `fpd_group_permissions` (`group_key`, `permission`) VALUES
    ('superuser', '*');
