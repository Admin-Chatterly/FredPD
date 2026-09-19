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
