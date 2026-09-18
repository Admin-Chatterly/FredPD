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
