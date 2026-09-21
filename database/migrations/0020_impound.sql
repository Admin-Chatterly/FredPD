-- 0020_impound.sql
--
-- Vehicle impound (spec 7.15; milestone M6): the fee clock, release gated on
-- payment plus, for an investigative or evidence hold, an investigator's
-- authorization. Fires `fredpd:vehicleImpounded` on creation, which
-- `spaning/events.lua` has been listening for since 0012 -- see that file's
-- own header.
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
--
-- =============================================================================
-- WHY `vehicle_id` IS NULLABLE, AND `plate` IS NOT
-- =============================================================================
--
-- An impound is written the moment a vehicle is taken in, from whatever the
-- officer can read off the plate -- and not every plate resolves to a
-- `fpd_vehicles` row. An out-of-state plate, a vehicle never entered into this
-- server's registry, or a plate typo'd past what `Repo.byPlate` can match, are
-- all still real impounds with a real fee clock. So `plate` is captured
-- directly and unconditionally, and `vehicle_id` is filled in only when
-- `repo.create` finds a matching registry row -- the same "best effort,
-- nullable" shape `fpd_vehicles.owner_person_id` already uses for a keeper the
-- registry cannot always identify.
--
-- `ON DELETE SET NULL`: a vehicle purged from the registry does not take the
-- fee history of every impound it was ever party to with it.
--
--
-- =============================================================================
-- THE HOLD REASON, THE AUTHORIZATION, AND WHY THEY ARE PAIRED
-- =============================================================================
--
-- `held_reason_key` is a closed allowlist (`Impound.isHeldReason`), not free
-- text: the NUI renders it with `t()` the same as every other reason key in
-- this suite (`Tvang.isTvangGrund`, `Court.isBeslutGrund`), and a sentence
-- typed into a key field is the defect that review has now caught in four
-- other modules.
--
-- Only `investigative` and `evidence` need an investigator's sign-off before
-- release (`Impound.needsAuthorization`) -- a car towed for expired tags or
-- left abandoned does not wait on anybody but its fee. `hold_authorized_by`/
-- `hold_authorized_at` are consequently paired and both nullable, the same
-- `ck_fpd_atal_disposition_decided` idiom 0016 uses: an authorization has an
-- author and a moment, or it has neither.
--
--
-- =============================================================================
-- THE FEE: WHOLE CURRENCY UNITS, MINIMUM ONE DAY
-- =============================================================================
--
-- No monetary column anywhere else in this schema sets a precedent for cents
-- or a fractional unit, so `fee_per_day` is a whole-number amount in the
-- server's own currency, as ESX itself stores money. `Impound.feeOwed`
-- (`server/modules/impound/service.lua`) is the arithmetic; this column is
-- only the rate. A released-same-day vehicle still owes one day's fee -- a
-- fraction of a day held is not a fraction of a day's storage cost to the
-- department -- which is why the service rounds every partial day up rather
-- than down, with a floor of one day even at zero elapsed time.

CREATE TABLE IF NOT EXISTS `fpd_impound` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `number`      VARCHAR(32)     NOT NULL COMMENT 'Counter kind `impound` (Appendix D): I{YY}-{#####}',

    `vehicle_id`  BIGINT UNSIGNED NULL COMMENT 'NULL when the plate does not resolve to a registry row',
    `plate`       VARCHAR(16)     NOT NULL COMMENT 'Captured directly, independent of vehicle_id',
    `model`       VARCHAR(191)    NULL,

    `held_reason_key` VARCHAR(64) NOT NULL COMMENT 'Locale key: investigative | evidence | abandoned | dui | unregistered | other',
    `hold_authorized_by` VARCHAR(32) NULL COMMENT 'Discord id of the investigator, investigative/evidence hold only',
    `hold_authorized_at` DATETIME(3) NULL,

    `fee_per_day` INT UNSIGNED    NOT NULL DEFAULT 0 COMMENT 'Whole currency units per day held',

    `impounded_at` DATETIME(3)    NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `impounded_by` VARCHAR(32)    NOT NULL COMMENT 'Discord id',

    `released_at` DATETIME(3)     NULL,
    `released_by` VARCHAR(32)     NULL,
    `fee_paid`    TINYINT(1)      NOT NULL DEFAULT 0,

    `classification` VARCHAR(16) NOT NULL DEFAULT 'internal',
    `version`     INT UNSIGNED    NOT NULL DEFAULT 1,

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_impound_number` (`agency_id`, `number`),
    -- "What is currently held" -- the screen's default list.
    KEY `idx_fpd_impound_agency_held` (`agency_id`, `released_at`),
    -- The plate lookup `Repo.byPlate` runs: the most recent open record for a
    -- given plate.
    KEY `idx_fpd_impound_agency_plate` (`agency_id`, `plate`),
    CONSTRAINT `fk_fpd_impound_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_impound_vehicle` FOREIGN KEY (`vehicle_id`)
        REFERENCES `fpd_vehicles` (`id`) ON DELETE SET NULL,
    CONSTRAINT `ck_fpd_impound_reason` CHECK (`held_reason_key` IN
        ('investigative', 'evidence', 'abandoned', 'dui', 'unregistered', 'other')),
    CONSTRAINT `ck_fpd_impound_authorized` CHECK (
        (`hold_authorized_by` IS NULL AND `hold_authorized_at` IS NULL)
        OR (`hold_authorized_by` IS NOT NULL AND `hold_authorized_at` IS NOT NULL)),
    CONSTRAINT `ck_fpd_impound_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret')),
    CONSTRAINT `ck_fpd_impound_plate` CHECK (CHAR_LENGTH(TRIM(`plate`)) > 0),
    CONSTRAINT `ck_fpd_impound_number` CHECK (CHAR_LENGTH(TRIM(`number`)) > 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;
