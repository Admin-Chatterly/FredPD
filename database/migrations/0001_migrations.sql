-- 0001_migrations.sql
--
-- Bookkeeping for the migration runner itself (spec 17.2, M1).
--
-- Invariant 8: this file has shipped. Never edit it; add a new migration.
--
-- `checksum` is what lets the runner refuse to start against an unexpected
-- schema (spec 16): if a shipped migration was edited after the fact, the
-- recorded checksum no longer matches the file and the server stops instead of
-- applying a half-known schema to production data.

CREATE TABLE IF NOT EXISTS `fpd_migrations` (
    `id`          INT UNSIGNED NOT NULL AUTO_INCREMENT,
    `name`        VARCHAR(191) NOT NULL,
    `checksum`    CHAR(64)     NOT NULL COMMENT 'SHA-256 of the file as applied',
    `applied_at`  DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `duration_ms` INT UNSIGNED NOT NULL DEFAULT 0,

    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_fpd_migrations_name` (`name`)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_unicode_ci;
