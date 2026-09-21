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
