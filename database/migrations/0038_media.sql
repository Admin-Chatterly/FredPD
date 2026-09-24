-- 0038_media.sql
--
-- The media ledger: every upload the server has asked the gateway for, and
-- whether it became a record (spec 3.7, 9, 13.2; ADR-019).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
-- An upload happens in three steps, and only the first and last are the
-- server's: it asks the gateway for a single-use upload URL (`begin`), the
-- NUI puts the bytes there, and the server attaches the stored file to a
-- record (`commit`). This table is what ties the last step to the first: a
-- commit names a `media_ref`, and only a ref this server issued, to this
-- officer, for this subject and purpose, within its lifetime, is attached to
-- anything. A ref typed in by hand, or one issued to somebody else, is
-- refused -- the gateway knows the file exists, but only this row says who
-- asked for it and why.
--
-- A `pending` row that is never committed is an upload nobody finished; the
-- retention sweep (13.3) removes both it and the file.

CREATE TABLE IF NOT EXISTS `fpd_media` (
    `media_ref`    VARCHAR(64)     NOT NULL,
    `agency_id`    VARCHAR(32)     NOT NULL,
    `purpose`      VARCHAR(24)     NOT NULL,
    `subject_id`   BIGINT UNSIGNED NOT NULL COMMENT 'The record the file is for, by purpose',
    `photo_kind`   VARCHAR(16)     NULL,
    `status`       VARCHAR(12)     NOT NULL DEFAULT 'pending',
    `created_by`   VARCHAR(32)     NOT NULL,
    `created_at`   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `committed_at` DATETIME(3)     NULL,

    PRIMARY KEY (`media_ref`),
    KEY `idx_fpd_media_pending` (`status`, `created_at`),
    CONSTRAINT `fk_fpd_media_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_media_purpose` CHECK (`purpose` IN ('person_photo')),
    CONSTRAINT `ck_fpd_media_status` CHECK (`status` IN ('pending', 'committed')),
    CONSTRAINT `ck_fpd_media_kind` CHECK (`photo_kind` IN ('mugshot', 'field', 'scar', 'mark', 'tattoo'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;
