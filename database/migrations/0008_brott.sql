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
