-- 0019_ordningsbot.sql
--
-- Ordningsbot: on-the-spot fixed-penalty citations, against a versioned
-- tariff (spec 7.11; milestone M6).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
--
-- =============================================================================
-- THE TARIFF IS A CATALOGUE, THE SAME SHAPE AS `fpd_brott` (0008)
-- =============================================================================
--
-- A citation issued under this year's parking fine must still read, next
-- year, as the amount it was actually issued under -- the identical argument
-- 0008's header makes for the straffskala. So `fpd_ordningsbot_tariff` is
-- versioned the same way: `code` (e.g. `parking`, `noise`, `littering`) is
-- the offence across time, a row is immutable once a citation cites it, and
-- an amount change is `retire` plus `insert`, never an UPDATE.
--
-- `current_marker` is the identical trick 0008 uses for `fpd_brott` (and 0005
-- for a person's primary photo): MariaDB has no partial unique index, so
-- "at most one current version per (agency, code)" is enforced by a generated
-- column that is `code` on a live row and NULL on a retired one -- NULLs do
-- not collide in a unique index, so any number of retired versions may exist
-- while at most one is current. This is a real database constraint, not a
-- rule the service layer merely promises to keep; `Repo.setTariff` still
-- retires before it inserts, in one transaction, because the unique index
-- allows exactly one live version per code and the insert would collide with
-- the row it is replacing if it ran first (`brott/repo.lua`'s
-- `Repo.createVersion` makes the same argument, in the same order).
--
--
-- =============================================================================
-- WHY `amount` IS A WHOLE-UNIT INT AND NOT A DECIMAL
-- =============================================================================
--
-- Nothing else in this suite stores a money amount yet -- no minor-unit
-- (öre/cents) column, no DECIMAL, no precedent either way -- so there is
-- nothing here to stay consistent with. INT UNSIGNED, whole SEK, is chosen
-- because every fine spec 7.11 names ("500 kr", "1500 kr") is a round number
-- an officer reads off a printed citation, never a fractional one, and a
-- DECIMAL(10,2) buys precision this module has no use for. If a future
-- module needs fractional currency, that module's migration is where the
-- suite's first minor-unit column belongs -- not retrofitted here onto a
-- table that has no use for it.
--
--
-- =============================================================================
-- THE CITATION ITSELF, AND WHY VOID/PAID/CONTESTED HAVE NO WAY BACK
-- =============================================================================
--
-- `fpd_ordningsbot` is the record a citation number is allocated for. Its
-- `status` moves exactly once, from `issued` to one of `paid`, `contested` or
-- `void` (`ordningsbot/service.lua`'s `Ordningsbot.mayTransition` is the
-- single definition of which moves are legal, and every write in
-- `ordningsbot/repo.lua` guards the same transition with
-- `WHERE ... AND status = 'issued'` so the database refuses the second one
-- even if a route bug did not). A contested citation is not resolved here --
-- 7.11 says contesting sends it to court, and this migration does not invent
-- a second disposition mechanism beside the one `fpd_atal` (0016) already
-- owns. Marking `contested` only stops the fine and the points clock; what
-- happens to the contest is a court module's business, not this table's.
--
-- **Payment is a deliberate scope-narrowing**, in the same spirit 0016's
-- header explains for "request more investigation": 7.11 says fines move
-- "through the billing bridge", and no such bridge exists in this repo (the
-- payment bridges spec 3 lists are billing-adjacent connectors this
-- milestone does not build). `ordningsbot.pay` marks `paid_at`/`status`
-- directly rather than waiting on integration work with nothing here to
-- integrate against yet. A real billing bridge, when one is built, writes to
-- the same column through the same route; nothing about this shape needs to
-- change to accept it.
--
-- Person and vehicle are both nullable and the table requires at least one:
-- a citation is routinely written against a parked or fleeing vehicle with
-- no confirmed driver, and a person-only citation (a written warning with no
-- plate involved) is equally real. Neither column being enough alone is why
-- `ck_fpd_ordningsbot_subject` requires one rather than the other.

-- -----------------------------------------------------------------------------
-- The tariff (the versioned catalogue)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_ordningsbot_tariff` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,

    `code`        VARCHAR(32)     NOT NULL COMMENT 'Stable across versions, e.g. parking, noise, littering',
    `label_key`   VARCHAR(191)    NOT NULL COMMENT 'Locale key, never a literal string (invariant 6)',
    `amount`      INT UNSIGNED    NOT NULL COMMENT 'Whole SEK units -- see header',
    `version`     INT UNSIGNED    NOT NULL DEFAULT 1,

    `effective_from` DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `retired_at`  DATETIME(3)     NULL COMMENT 'NULL means this is the current version for its code',

    -- Currency, the same generated-column trick 0008 uses for `fpd_brott`.
    -- See header.
    `current_marker` VARCHAR(32)
        GENERATED ALWAYS AS (IF(`retired_at` IS NULL, `code`, NULL)) STORED,

    `created_by`  VARCHAR(32)     NULL COMMENT 'Discord id of the admin who set this version',
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_ordningsbot_tariff_version` (`agency_id`, `code`, `version`),
    UNIQUE KEY `uq_fpd_ordningsbot_tariff_current` (`agency_id`, `current_marker`),
    UNIQUE KEY `uq_fpd_ordningsbot_tariff_id_agency` (`id`, `agency_id`),
    KEY `idx_fpd_ordningsbot_tariff_code` (`agency_id`, `code`),
    CONSTRAINT `fk_fpd_ordningsbot_tariff_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_ordningsbot_tariff_code` CHECK (CHAR_LENGTH(TRIM(`code`)) > 0),
    CONSTRAINT `ck_fpd_ordningsbot_tariff_label` CHECK (CHAR_LENGTH(TRIM(`label_key`)) > 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- The citation
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_ordningsbot` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `number`      VARCHAR(32)     NOT NULL COMMENT 'Counter kind `citation` (Appendix D): {AGENCY}-T{YY}-{######}',

    `tariff_id`   BIGINT UNSIGNED NOT NULL COMMENT 'One immutable tariff version -- never "the current tariff"',

    `person_id`   BIGINT UNSIGNED NULL COMMENT 'Nullable -- a citation may be issued against a vehicle alone',
    `vehicle_id`  BIGINT UNSIGNED NULL,

    `issued_by`   VARCHAR(32)     NOT NULL COMMENT 'Discord id',
    `issued_at`   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    `status`      VARCHAR(16)     NOT NULL DEFAULT 'issued',

    -- Set together, once, on a void. See header for why there is no way back
    -- from any of the three terminal statuses.
    `void_reason_key` VARCHAR(64) NULL COMMENT 'Locale key',
    `voided_by`   VARCHAR(32)     NULL,
    `voided_at`   DATETIME(3)     NULL,

    `paid_at`     DATETIME(3)     NULL,
    `contested_at` DATETIME(3)    NULL,

    `classification` VARCHAR(16)  NOT NULL DEFAULT 'internal',
    `version`     INT UNSIGNED    NOT NULL DEFAULT 1,
    `updated_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_ordningsbot_number` (`agency_id`, `number`),
    UNIQUE KEY `uq_fpd_ordningsbot_id_agency` (`id`, `agency_id`),
    KEY `idx_fpd_ordningsbot_agency_issued` (`agency_id`, `issued_at`),
    KEY `idx_fpd_ordningsbot_agency_status` (`agency_id`, `status`),
    KEY `idx_fpd_ordningsbot_person` (`person_id`),
    KEY `idx_fpd_ordningsbot_vehicle` (`vehicle_id`),
    CONSTRAINT `fk_fpd_ordningsbot_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    -- RESTRICT, not CASCADE: a tariff version a citation cites must never be
    -- removable out from under it (the same reasoning `fk_fpd_atal_brott_brott`
    -- gives for a charge's catalogue row).
    CONSTRAINT `fk_fpd_ordningsbot_tariff` FOREIGN KEY (`tariff_id`)
        REFERENCES `fpd_ordningsbot_tariff` (`id`) ON DELETE RESTRICT,
    -- Composite, agency-checked FKs, the same shape `fpd_vehicle_plates` uses:
    -- a citation cannot drift into naming another agency's person or vehicle.
    -- Nullable columns in a multi-column FK are simply not checked while
    -- either half is NULL, which is exactly what a citation naming only a
    -- vehicle (or only a person) needs.
    CONSTRAINT `fk_fpd_ordningsbot_person` FOREIGN KEY (`person_id`, `agency_id`)
        REFERENCES `fpd_persons` (`id`, `agency_id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_fpd_ordningsbot_vehicle` FOREIGN KEY (`vehicle_id`, `agency_id`)
        REFERENCES `fpd_vehicles` (`id`, `agency_id`) ON DELETE RESTRICT,
    CONSTRAINT `ck_fpd_ordningsbot_status` CHECK (`status` IN
        ('issued', 'paid', 'contested', 'void')),
    CONSTRAINT `ck_fpd_ordningsbot_void` CHECK (
        (`void_reason_key` IS NULL AND `voided_by` IS NULL AND `voided_at` IS NULL)
        OR (`void_reason_key` IS NOT NULL AND `voided_by` IS NOT NULL AND `voided_at` IS NOT NULL)),
    CONSTRAINT `ck_fpd_ordningsbot_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret')),
    CONSTRAINT `ck_fpd_ordningsbot_subject` CHECK (
        `person_id` IS NOT NULL OR `vehicle_id` IS NOT NULL),
    CONSTRAINT `ck_fpd_ordningsbot_number` CHECK (CHAR_LENGTH(TRIM(`number`)) > 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;
