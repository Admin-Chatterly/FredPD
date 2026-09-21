-- 0015_surveillance.sql
--
-- Hemlig avlyssning och annan hemlig tvångsmedelsanvändning: HAK, HRA,
-- spårsändare, kameraövervakning (spec 9; milestone M5).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
--
-- =============================================================================
-- WHY THIS TABLE HAS A JUDGE AND 0011's DOES NOT
-- =============================================================================
--
-- 0011 argued at length that Swedish procedure gives the ordinary coercive
-- measures -- husrannsakan, kroppsvisitation -- to the förundersökningsledare,
-- police or prosecutor, and a court only where RB actually requires one. The
-- secret measures are exactly that "where RB requires one": hemlig
-- avlyssning av elektronisk kommunikation (RB 27:18), hemlig
-- rumsavlyssning (RB 27:20d), and the spårsändare and kameraövervakning
-- FredPD adds alongside them are **tingsrätt-decided**, on the åklagare's
-- application, precisely because they reach somebody who does not know they
-- are being watched and cannot object before the fact. That is also why this
-- table's shape mirrors 0010's häktning stage rather than 0011's single
-- decision: an åklagare applies, and only a domare's grant makes it live.
--
--
-- =============================================================================
-- REQUEST, THEN DECISION -- NOT ONE STEP
-- =============================================================================
--
-- `status` walks `begard` (requested) -> `beviljad` (granted) or `avslagen`
-- (refused) -> optionally `upphavd` (revoked before its window ran out, RB
-- 27:23 -- grounds may cease before the window does). `ck_fpd_hak_chain`
-- enforces that each stage's columns are actually filled, the same reasoning
-- 0010's `ck_fpd_frihet_chain` uses for the frihetsberövande chain. There is
-- no `verkstalld` stage here: unlike a husrannsakan, a granted interception
-- does not wait to be "carried out" as a separate recorded act -- observing
-- starts as soon as `fpd_hak_sessions` gets a row, which is exactly what that
-- table is for.
--
--
-- =============================================================================
-- WHAT IS DELIBERATELY NOT HERE
-- =============================================================================
--
-- **Media.** `fpd_hak_intercepts.media_ref` is a reference, never a URL
-- (invariant 9, spec 3.7) -- the gateway resolves it to a signed link when C1
-- of the remaining-work plan builds media upload. Nothing here presumes its
-- shape beyond a string.
--
-- **A dedicated access-read log.** `Repo.access.read` already audits every
-- restricted read against the generic append-only audit log (invariant 11),
-- and `surveillance` has been in `RECORD_TYPES` (0001, `access/repo.lua`)
-- since M1 for exactly this. A second, per-module log table here would be a
-- second definition of "who read this", and the two would drift the way
-- 0013's header warns fixtures do. `fpd_hak_intercepts` is a case journal --
-- what was captured -- not an access log; those are different questions, and
-- 0010's `fpd_frihet_log` is the same distinction for the frihetsberövande
-- chain.

-- -----------------------------------------------------------------------------
-- The decision
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `fpd_hak` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`   VARCHAR(32)     NOT NULL,
    `number`      VARCHAR(32)     NOT NULL COMMENT 'Counter kind `hak` (Appendix D)',

    -- A secret measure is always taken inside an investigation; there is no
    -- "no FU" case the way an ordinary husrannsakan sometimes has one.
    `fu_id`       BIGINT UNSIGNED NOT NULL,

    `target_kind` VARCHAR(16)     NOT NULL,
    -- Set only when the target is a record FredPD already holds (a person, a
    -- vehicle). A telephone number or an address is not a foreign key into
    -- anything, so `target_label` (below) is what most rows actually carry.
    `target_id`   BIGINT UNSIGNED NULL,
    -- The phone number, the room, the vehicle's description -- whatever a
    -- court decision names that is not one of this suite's own ids. Free
    -- text, like `fpd_tvangsmedel.target_label`.
    `target_label` VARCHAR(191)   NULL,

    `method`      VARCHAR(24)     NOT NULL,

    -- Why, as a locale key (invariant 6), never a sentence -- the NUI renders
    -- it with `t()` for both the åklagare's application and the domare's
    -- reading of it.
    `grund`       VARCHAR(128)    NOT NULL,

    `status`      VARCHAR(16)     NOT NULL DEFAULT 'begard',

    `requested_by` VARCHAR(32)    NOT NULL COMMENT 'Discord id of the åklagare',
    `requested_at` DATETIME(3)    NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    `decided_by`  VARCHAR(32)     NULL COMMENT 'Discord id of the domare',
    `decided_at`  DATETIME(3)     NULL,
    `refused_grund` VARCHAR(128)  NULL COMMENT 'Locale key, set only when avslagen',

    -- The court's own reference for its beslut -- what an åklagare or domare
    -- would quote if asked to justify this outside the game.
    `court_ref`   VARCHAR(64)     NULL,

    -- The window. NULL until granted; `Surveillance.isValid` is the one
    -- definition of "live", the same split 0011 makes for `Tvang.isValid`.
    `valid_from`  DATETIME(3)     NULL,
    `valid_until` DATETIME(3)     NULL,

    `upphavd_at`  DATETIME(3)     NULL,
    `upphavd_by`  VARCHAR(32)     NULL,
    `upphavd_grund` VARCHAR(128)  NULL COMMENT 'Locale key: why RB 27:23 was invoked',

    `classification` VARCHAR(16)  NOT NULL DEFAULT 'confidential',
    `version`     INT UNSIGNED    NOT NULL DEFAULT 1,
    `updated_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_hak_number` (`agency_id`, `number`),
    UNIQUE KEY `uq_fpd_hak_id_agency` (`id`, `agency_id`),
    KEY `idx_fpd_hak_fu` (`fu_id`),
    -- The list an åklagare or domare reads: their own agency's open requests
    -- and grants, most recent first.
    KEY `idx_fpd_hak_agency_status` (`agency_id`, `status`, `requested_at`),
    -- The liveness question -- is there a live measure on this target --
    -- mirroring `idx_fpd_tvang_valid`'s shape.
    KEY `idx_fpd_hak_target_valid` (`target_kind`, `target_id`, `valid_until`),
    CONSTRAINT `fk_fpd_hak_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_hak_fu` FOREIGN KEY (`fu_id`)
        REFERENCES `fpd_forundersokning` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `ck_fpd_hak_target` CHECK (`target_kind` IN
        ('person', 'phone', 'vehicle', 'location')),
    CONSTRAINT `ck_fpd_hak_method` CHECK (`method` IN
        ('hak', 'hra', 'sparsandare', 'kameraovervakning')),
    CONSTRAINT `ck_fpd_hak_status` CHECK (`status` IN
        ('begard', 'beviljad', 'avslagen', 'upphavd')),
    CONSTRAINT `ck_fpd_hak_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret')),
    -- A target has to be *something*: a record this suite already holds, or a
    -- label naming what it does not (a phone number, a room). The same
    -- reasoning as `ck_fpd_spaning_something`.
    CONSTRAINT `ck_fpd_hak_something` CHECK (
        `target_id` IS NOT NULL OR CHAR_LENGTH(TRIM(COALESCE(`target_label`, ''))) > 0),
    -- The chain: each stage requires its own decision-maker and, for a grant,
    -- the window it authorises.
    CONSTRAINT `ck_fpd_hak_chain` CHECK (
        (`status` <> 'begard'   OR (`requested_at` IS NOT NULL AND `requested_by` IS NOT NULL))
        AND (`status` <> 'beviljad' OR (`decided_at` IS NOT NULL AND `decided_by` IS NOT NULL
                                        AND `valid_from` IS NOT NULL AND `valid_until` IS NOT NULL))
        AND (`status` <> 'avslagen' OR (`decided_at` IS NOT NULL AND `decided_by` IS NOT NULL))
        AND (`status` <> 'upphavd'  OR (`upphavd_at` IS NOT NULL AND `upphavd_by` IS NOT NULL
                                        AND `decided_at` IS NOT NULL))),
    CONSTRAINT `ck_fpd_hak_window` CHECK (
        `valid_from` IS NULL OR `valid_until` IS NULL OR `valid_until` > `valid_from`),
    CONSTRAINT `ck_fpd_hak_number` CHECK (CHAR_LENGTH(TRIM(`number`)) > 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Observer sessions
-- -----------------------------------------------------------------------------

-- Written by the server the moment an authorized observer starts listening
-- and again when they stop (spec 9's "sessions are written by the server").
-- No client ever sends a session row; it is a consequence of a route call,
-- the same way `fpd_frihet_log` is.

CREATE TABLE IF NOT EXISTS `fpd_hak_sessions` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `hak_id`      BIGINT UNSIGNED NOT NULL,

    `observer`    VARCHAR(32)     NOT NULL COMMENT 'Discord id',
    `started_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `ended_at`    DATETIME(3)     NULL,
    -- Spec 9's "product log with minimization notes": what was relevant and
    -- what was not, the record an observer keeps to show they did not listen
    -- past what the decision authorised.
    `minimization_note` VARCHAR(500) NULL,

    PRIMARY KEY (`id`),
    KEY `idx_fpd_hak_sessions_hak` (`hak_id`, `started_at`),
    -- The open-session question: is anybody listening right now. Short list,
    -- narrow index, the same shape as `idx_fpd_frihet_open`.
    KEY `idx_fpd_hak_sessions_open` (`observer`, `ended_at`),
    CONSTRAINT `fk_fpd_hak_sessions_hak` FOREIGN KEY (`hak_id`)
        REFERENCES `fpd_hak` (`id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_hak_sessions_order` CHECK (
        `ended_at` IS NULL OR `ended_at` >= `started_at`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Captures
-- -----------------------------------------------------------------------------

-- Append-only, like `fpd_frihet_log` and for the same reason: the question
-- asked about an interception afterwards is always "what was captured, and
-- when", and a row that could be edited answers it with what somebody would
-- prefer had been captured.

CREATE TABLE IF NOT EXISTS `fpd_hak_intercepts` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `hak_id`      BIGINT UNSIGNED NOT NULL,

    -- A locale key naming what kind of capture this is (call, message,
    -- position, audio, image, …), for the same reason `fpd_frihet_log.kind`
    -- is one rather than an enum: what a method can capture is a matter of
    -- which methods a department has built out, not of what RB names, and a
    -- CHECK here would need a migration before a server could log its own
    -- interceptions.
    `kind`        VARCHAR(64)     NOT NULL,
    `occurred_at` DATETIME(3)     NOT NULL,
    `summary`     VARCHAR(500)    NULL COMMENT 'Free text: an observer describing what was captured',
    -- A reference, never a URL (invariant 9). The gateway resolves this to a
    -- signed link; nothing here presumes what resolves it.
    `media_ref`   VARCHAR(191)    NULL,

    `classification` VARCHAR(16)  NOT NULL DEFAULT 'confidential',

    `logged_by`   VARCHAR(32)     NULL,
    `logged_at`   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    KEY `idx_fpd_hak_intercepts_hak` (`hak_id`, `occurred_at`),
    CONSTRAINT `fk_fpd_hak_intercepts_hak` FOREIGN KEY (`hak_id`)
        REFERENCES `fpd_hak` (`id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_hak_intercepts_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret')),
    CONSTRAINT `ck_fpd_hak_intercepts_kind` CHECK (CHAR_LENGTH(TRIM(`kind`)) > 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;
