-- 0003_intel.sql
--
-- The intelligence module (spec 10): PD-Span's data model, ported from
-- Supabase/Postgres onto the server's own MariaDB so everything persists in the
-- game database rather than in a separate hosted service.
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
-- What changed in the port, and why:
--
--   * `uuid` primary keys become `BIGINT UNSIGNED AUTO_INCREMENT` (spec 13.1).
--
-- The existing PD-Span data is deliberately NOT migrated: this starts empty and
-- the register is built up in game. Nothing here carries the old identifiers.
-- If that decision is ever revisited, a later migration adds a nullable unique
-- `span_uuid` per table and the import keys on it -- it is an ALTER, not a
-- redesign.
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
-- Deliberately lost: pg_trgm typo tolerance. Search is substring-based, as
-- PD-Span's primary path already was. Fuzzy ranking can come back later.

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
