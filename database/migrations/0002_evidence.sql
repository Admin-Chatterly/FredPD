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
    CONSTRAINT `fk_fpd_forensic_index_evidence` FOREIGN KEY (`evidence_id`)
        REFERENCES `fpd_evidence` (`id`) ON DELETE SET NULL,
    CONSTRAINT `ck_fpd_forensic_index_kind` CHECK (`index_kind` IN
        ('dna_convicted', 'dna_suspect', 'dna_trace', 'fingerprint', 'fingerprint_latent', 'ballistics')),
    CONSTRAINT `ck_fpd_forensic_index_subject` CHECK (
        (`identifier` IS NOT NULL) + (`evidence_id` IS NOT NULL) >= 1)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;
