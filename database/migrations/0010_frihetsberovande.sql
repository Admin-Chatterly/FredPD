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
