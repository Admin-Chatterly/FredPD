-- 0028_person_pending_identity.sql
--
-- Who an unidentified arrestee actually is, held where nobody can read it
-- (spec 7.2.1, 8.8).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
--
-- =============================================================================
-- WHY
-- =============================================================================
--
-- An officer can arrest somebody who refuses to show ID on the ground
-- `identitet_oklar` (`field.person.unidentified`). They become a person with
-- no name and no identifier, and the ten-print at booking is what says who
-- they are.
--
-- The ten-print reads the identifier of whoever stands at the terminal. Without
-- this table nothing tied that ped to the arrest: an officer could print a
-- bystander against an open booking and learn who *they* are, or bind the
-- bystander's identity onto the arrestee's record. So the arrest records, out
-- of sight, which character was arrested, and the capture refuses any other.
--
-- Hidden truth in the sense of 8.1: never selected by a read that reaches a
-- client, never returned, never audited by value. It exists only to be
-- compared against, and the row goes when the person is identified.

CREATE TABLE IF NOT EXISTS `fpd_person_pending_identity` (
    `person_id`   BIGINT UNSIGNED NOT NULL,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `identifier`  VARCHAR(191)    NOT NULL COMMENT 'ESX character identifier of the arrested ped. Hidden truth.',
    `created_by`  VARCHAR(32)     NOT NULL COMMENT 'Discord id of the arresting officer',
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`person_id`),
    CONSTRAINT `fk_fpd_person_pending_identity_person` FOREIGN KEY (`person_id`)
        REFERENCES `fpd_persons` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_person_pending_identity_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;
