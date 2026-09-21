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
