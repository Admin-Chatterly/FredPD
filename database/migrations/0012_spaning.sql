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
