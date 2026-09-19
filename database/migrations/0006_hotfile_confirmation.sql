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
