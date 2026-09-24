-- 0030_lab_candidates.sql
--
-- Who a fingerprint search pointed at (spec 8.1.3, 8.7, 8.8).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
-- A print comparison or index search that hits a reference used to answer
-- `candidate_match` and nothing else: a lead that named nobody, so the
-- investigation it was run for could not follow it anywhere. This records
-- which person in the master index the matching reference belongs to --
-- resolved inside the database from `fpd_forensic_index.identifier` to
-- `fpd_persons.identifier`, so no profile and no identifier is ever read
-- into the application to do it.
--
-- It is a lead, not an identification (8.1.3): the screen says so, and
-- confirming it still takes a fresh reference sample. A reader sees a
-- candidate only if they may read that person's record and the case.
--
-- It also adds `fpd_lab_analyses.completed_by`. Any analyst may now finish
-- work whose clock has run out, not only the one who started it, so who
-- signed the result is a fact of its own: `assigned_to` is who took the work
-- on, `completed_by` who wrote it up (`system` for the automatic lab).

CREATE TABLE IF NOT EXISTS `fpd_lab_candidates` (
    `analysis_id` BIGINT UNSIGNED NOT NULL,
    `person_id`   BIGINT UNSIGNED NOT NULL,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`analysis_id`, `person_id`),
    KEY `idx_fpd_lab_candidates_person` (`agency_id`, `person_id`),
    CONSTRAINT `fk_fpd_lab_candidates_analysis` FOREIGN KEY (`analysis_id`)
        REFERENCES `fpd_lab_analyses` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_lab_candidates_person` FOREIGN KEY (`person_id`)
        REFERENCES `fpd_persons` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_lab_candidates_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

ALTER TABLE `fpd_lab_analyses`
    ADD COLUMN IF NOT EXISTS `completed_by` VARCHAR(32) NULL
        COMMENT 'Discord id of whoever signed the result, or system' AFTER `completed_at`;
