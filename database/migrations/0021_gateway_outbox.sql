-- 0021_gateway_outbox.sql
--
-- The gateway bridge's outbox (spec 3.7, C4). Not scoped by agency: the
-- gateway is one process per server, not per agency, and a retry queue that
-- also had to carry an agency id would be a fact this table does not need in
-- order to resend a request.
--
-- Invariant 8: append-only. Never edit this file once it has shipped.

CREATE TABLE IF NOT EXISTS `fpd_gateway_outbox` (
    `id`              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `kind`            VARCHAR(32)     NOT NULL COMMENT 'e.g. pdf.render',
    `payload`         JSON            NOT NULL COMMENT 'The request body, resent as-is',
    `attempts`        INT UNSIGNED    NOT NULL DEFAULT 0,
    `last_error`      VARCHAR(191)    NULL,
    `last_attempt_at` DATETIME(3)     NULL,
    `created_at`      DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (`id`),
    KEY `idx_fpd_gateway_outbox_created` (`created_at`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;
