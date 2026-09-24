-- 0041_cameras.sql
--
-- Cameras (spec 7.19): CCTV, body-worn and dash cameras, and the footage
-- request that lets an investigator look through one and keep a still.
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
-- A CCTV camera is a placement of kind `cctv_camera`, set up in the world like
-- a terminal (spec 3.10), never a coordinate in config. A body-worn camera is
-- an officer's issued `bodycam` (7.22's equipment); a dash camera is the
-- agency vehicle an officer is in. Live view is audited per view.
--
-- A footage request names one source and a window of time, and why. Once a
-- supervisor approves it, the requester may look through that source while
-- the window is open and keep one still frame on the request: the still is a
-- file in the media store (ADR-019), attached here and to nothing else, and
-- the request is what an FU links to.
--
-- Number: counter kind `footage`, `F{YY}-{#####}` (Appendix D).

-- A still is a new purpose for the media ledger (0038).
ALTER TABLE `fpd_media`
    DROP CONSTRAINT IF EXISTS `ck_fpd_media_purpose`;

ALTER TABLE `fpd_media`
    ADD CONSTRAINT IF NOT EXISTS `ck_fpd_media_purpose` CHECK (`purpose` IN ('person_photo', 'footage_still'));

CREATE TABLE IF NOT EXISTS `fpd_footage_requests` (
    `id`             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`      VARCHAR(32)     NOT NULL,
    `number`         VARCHAR(32)     NOT NULL,
    `source`         VARCHAR(16)     NOT NULL,
    `camera_id`      BIGINT UNSIGNED NULL COMMENT 'The cctv_camera placement, for a CCTV request',
    `officer_id`     BIGINT UNSIGNED NULL COMMENT 'Whose body-worn or dash camera',
    `window_from`    DATETIME(3)     NOT NULL,
    `window_to`      DATETIME(3)     NOT NULL,
    `reason`         VARCHAR(500)    NOT NULL,
    `fu_id`          BIGINT UNSIGNED NULL,
    `status`         VARCHAR(16)     NOT NULL DEFAULT 'requested',
    `requested_by`   VARCHAR(32)     NOT NULL,
    `requested_at`   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `decided_by`     VARCHAR(32)     NULL,
    `decided_at`     DATETIME(3)     NULL,
    `decision_note`  VARCHAR(500)    NULL,
    `still_ref`      VARCHAR(64)     NULL,
    `still_by`       VARCHAR(32)     NULL,
    `still_at`       DATETIME(3)     NULL,
    `classification` VARCHAR(16)     NOT NULL DEFAULT 'internal',
    `version`        INT UNSIGNED    NOT NULL DEFAULT 1,

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_footage_number` (`agency_id`, `number`),
    KEY `idx_fpd_footage_status` (`agency_id`, `status`, `requested_at`),
    KEY `idx_fpd_footage_requester` (`agency_id`, `requested_by`, `requested_at`),
    CONSTRAINT `fk_fpd_footage_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_fpd_footage_camera` FOREIGN KEY (`camera_id`)
        REFERENCES `fpd_placements` (`id`) ON DELETE SET NULL,
    CONSTRAINT `fk_fpd_footage_officer` FOREIGN KEY (`officer_id`)
        REFERENCES `fpd_officers` (`id`) ON DELETE SET NULL,
    CONSTRAINT `fk_fpd_footage_fu` FOREIGN KEY (`fu_id`)
        REFERENCES `fpd_forundersokning` (`id`) ON DELETE SET NULL,
    CONSTRAINT `ck_fpd_footage_source` CHECK (`source` IN ('cctv', 'bodycam', 'dashcam')),
    CONSTRAINT `ck_fpd_footage_status` CHECK (`status` IN ('requested', 'approved', 'denied')),
    CONSTRAINT `ck_fpd_footage_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret')),
    CONSTRAINT `ck_fpd_footage_window` CHECK (`window_to` > `window_from`),
    CONSTRAINT `ck_fpd_footage_decided` CHECK (
        (`status` = 'requested' AND `decided_by` IS NULL AND `decided_at` IS NULL)
        OR (`status` <> 'requested' AND `decided_by` IS NOT NULL AND `decided_at` IS NOT NULL))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;
