-- 0018_booking.sql
--
-- Inskrivning i arrest: cell assignment and the property inventory (spec 7.9;
-- milestone M6).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
--
-- =============================================================================
-- WHERE THE GRIPANDE CHAIN STOPS, AND WHERE THIS PICKS IT UP
-- =============================================================================
--
-- 0010's own header names this migration before it existed: "Inskrivning i
-- arrest (booking): the mugshot, the ten-print capture and the property
-- inventory of 7.9's second half. That is M6 ... A frihetsberövande row will
-- link to it when it exists; nothing here presumes its shape." This is that
-- link. `fpd_booking.frihet_id` is a foreign key to `fpd_frihetsberovande`,
-- UNIQUE so a chain is booked at most once, and RESTRICT so a booking record
-- can never be orphaned by deleting the chain it documents -- the same
-- reasoning `fk_fpd_atal_fu` gives in 0016.
--
-- The mugshot and ten-print capture are not built here (they need the booking
-- terminal and the camera, per 0010's own header) -- only the two facts 7.9
-- asks M6 for: which cell somebody was put in, and what was taken from them.
--
--
-- =============================================================================
-- WHY THIS IS A SEPARATE TABLE AND NOT MORE COLUMNS ON `fpd_frihetsberovande`
-- =============================================================================
--
-- The chain records a legal decision (RB 24:7/24:6/24:13) made by an officer,
-- a prosecutor or a court, at the moment each of those people made it, and
-- 0010's own header explains at length why its stage columns are written once
-- and never updated. Booking is a different kind of fact entirely: a
-- custodial administrative act (who is physically holding this person and
-- where, and what is in the property room for them) that can be corrected --
-- a cell reassignment, an inventory addition -- without that correction
-- touching a single statutory clock. Folding it into `fpd_frihetsberovande`
-- would mean either giving that table a second, looser writability rule for
-- some of its columns, or leaving `cell` and the property list as an
-- unenforced convention bolted onto a record whose whole design is that
-- nothing about it moves quietly.
--
-- One booking per chain (`uq_fpd_booking_frihet`): a person is gripen once
-- and released once per chain (0010's header again -- a re-arrest is a new
-- chain with its own number), so there is exactly one cell assignment and one
-- property inventory to record against it.
--
--
-- =============================================================================
-- RELEASE REASON, AND WHY IT IS A LOCALE KEY
-- =============================================================================
--
-- `release_reason_key` is checked server-side against `Booking.isReleaseReason`
-- before it is ever written (`booking/service.lua`) -- the same closed-list
-- discipline `Court.isBeslutGrund` and `Personnel.isDisciplineCategory` use,
-- for the reason their own modules give: the NUI renders it with `t()`, and a
-- free string accepted here would print verbatim through `t()` in both
-- locales the day it did not match a key (invariant 6, the exact defect four
-- other modules had before this one was reviewed).
--
-- `item_label` on `fpd_booking_property`, by contrast, is deliberately free
-- text and is never passed to `t()` anywhere -- it is an officer's own
-- inventory note ("black leather wallet, $40 cash", "iPhone, cracked screen"),
-- not a value drawn from a closed list, and there is no finite catalogue of
-- what a person might be carrying.

-- -----------------------------------------------------------------------------
-- The booking
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_booking` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `number`      VARCHAR(32)     NOT NULL COMMENT 'Counter kind `booking` (Appendix D): B{YY}-{#####}',

    `frihet_id`   BIGINT UNSIGNED NOT NULL COMMENT 'The gripande/häktning chain this booking is for',
    `person_id`   BIGINT UNSIGNED NOT NULL,

    `cell`        VARCHAR(32)     NULL,

    `booked_at`   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `booked_by`   VARCHAR(32)     NOT NULL COMMENT 'Discord id of the booking officer',

    -- Release from custody. Not the same fact as `fpd_frihetsberovande.frigiven_at`
    -- -- that column is when the chain's decision-maker (officer, åklagare,
    -- domare or the automatic RB 24:13 outcome) ended the frihetsberövande;
    -- this one is when the arrest terminal actually let this person out the
    -- door, cell vacated and property returned. The two are ordinarily close
    -- together and are never the same write.
    `released_at` DATETIME(3)     NULL,
    `released_by` VARCHAR(32)     NULL,
    `release_reason_key` VARCHAR(64) NULL COMMENT 'Locale key, checked against Booking.isReleaseReason',

    `classification` VARCHAR(16)  NOT NULL DEFAULT 'internal',
    `version`     INT UNSIGNED    NOT NULL DEFAULT 1,
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_booking_number` (`agency_id`, `number`),
    -- One booking per chain (see header).
    UNIQUE KEY `uq_fpd_booking_frihet` (`frihet_id`),
    KEY `idx_fpd_booking_person` (`person_id`),
    KEY `idx_fpd_booking_agency` (`agency_id`, `booked_at`),
    CONSTRAINT `fk_fpd_booking_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    -- RESTRICT: a booking record must never be orphaned by deleting the chain
    -- it documents (there is no delete path on `fpd_frihetsberovande` at all,
    -- per 0010's own header, but the constraint says so rather than assuming
    -- it).
    CONSTRAINT `fk_fpd_booking_frihet` FOREIGN KEY (`frihet_id`)
        REFERENCES `fpd_frihetsberovande` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_fpd_booking_person` FOREIGN KEY (`person_id`)
        REFERENCES `fpd_persons` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `ck_fpd_booking_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret')),
    CONSTRAINT `ck_fpd_booking_number` CHECK (CHAR_LENGTH(TRIM(`number`)) > 0),
    -- Paired: a release is recorded as one unit or not at all, the same shape
    -- `ck_fpd_atal_disposition_decided` (0016) and `ck_fpd_cert_revoked`
    -- (0017) both use.
    CONSTRAINT `ck_fpd_booking_released` CHECK (
        (`released_at` IS NULL AND `released_by` IS NULL AND `release_reason_key` IS NULL)
        OR (`released_at` IS NOT NULL AND `released_by` IS NOT NULL AND `release_reason_key` IS NOT NULL))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- The property inventory
--
-- `agency_id` is denormalized onto this table rather than left to a join
-- through `fpd_booking`, so every write here -- in particular
-- `Repo.releaseProperty` -- is scoped by a direct `WHERE id = ? AND
-- agency_id = ? AND booking_id = ?` the way this codebase generally prefers
-- (spec 3.4's parameterized-and-scoped rule, read literally) rather than a
-- write that trusts a join to enforce the boundary.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_booking_property` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `booking_id`  BIGINT UNSIGNED NOT NULL,

    `item_label`  VARCHAR(191)    NOT NULL COMMENT 'Free text -- an officer''s own inventory note, never rendered through t() (invariant 6)',
    `quantity`    SMALLINT UNSIGNED NOT NULL DEFAULT 1,

    `logged_at`   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `logged_by`   VARCHAR(32)     NOT NULL COMMENT 'Discord id of the officer who logged it',

    `released_at` DATETIME(3)     NULL,
    `released_by` VARCHAR(32)     NULL,

    PRIMARY KEY (`id`),
    KEY `idx_fpd_booking_property_booking` (`booking_id`, `released_at`),
    CONSTRAINT `fk_fpd_booking_property_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_booking_property_booking` FOREIGN KEY (`booking_id`)
        REFERENCES `fpd_booking` (`id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_booking_property_label` CHECK (CHAR_LENGTH(TRIM(`item_label`)) > 0),
    CONSTRAINT `ck_fpd_booking_property_quantity` CHECK (`quantity` >= 1),
    -- Paired, the same shape `ck_fpd_booking_released` above uses.
    CONSTRAINT `ck_fpd_booking_property_released` CHECK (
        (`released_at` IS NULL AND `released_by` IS NULL)
        OR (`released_at` IS NOT NULL AND `released_by` IS NOT NULL))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;
