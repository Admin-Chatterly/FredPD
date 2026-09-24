-- 0039_documents.sql
--
-- Printed documents (spec 7.28, ADR-020).
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
-- A document is a record as it read the moment it was printed: its number
-- (Appendix D, `{AGENCY}-D{YY}-{######}`), what it was printed from, who
-- printed it, and the printed content itself (`payload`, the same title,
-- fields and editor-JSON body the paper copy carries and the PDF is rendered
-- from). The record it was printed from goes on changing; the document does
-- not, which is what a copy handed across a counter is.
--
-- `media_ref` is the rendered PDF when one was made (the gateway is optional,
-- 3.7); a paper copy needs nothing but this row and an inventory item.

CREATE TABLE IF NOT EXISTS `fpd_documents` (
    `id`             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `agency_id`      VARCHAR(32)     NOT NULL,
    `number`         VARCHAR(32)     NOT NULL,
    `kind`           VARCHAR(16)     NOT NULL,
    `subject_id`     BIGINT UNSIGNED NOT NULL COMMENT 'The record printed, by kind',
    `title`          VARCHAR(191)    NOT NULL,
    `classification` VARCHAR(16)     NOT NULL DEFAULT 'internal',
    `payload`        MEDIUMTEXT      NOT NULL COMMENT 'The document as printed, JSON',
    `media_ref`      VARCHAR(64)     NULL,
    `printed_by`     VARCHAR(32)     NOT NULL,
    `printed_at`     DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_documents_number` (`agency_id`, `number`),
    KEY `idx_fpd_documents_subject` (`agency_id`, `kind`, `subject_id`),
    CONSTRAINT `fk_fpd_documents_agency` FOREIGN KEY (`agency_id`)
        REFERENCES `fpd_agencies` (`id`) ON DELETE CASCADE,
    CONSTRAINT `ck_fpd_documents_kind` CHECK (`kind` IN ('citation', 'anmalan', 'custody')),
    CONSTRAINT `ck_fpd_documents_class` CHECK (`classification` IN
        ('open', 'internal', 'restricted', 'confidential', 'secret'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;
