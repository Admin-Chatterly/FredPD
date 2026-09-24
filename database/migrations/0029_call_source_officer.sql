-- 0029_call_source_officer.sql
--
-- Lets a call be raised by the officer who is standing at it (spec 7.16,
-- `call.self_initiate`): a traffic stop or something seen on patrol, without
-- the dispatch console.
--
-- Invariant 8: append-only. Never edit this file once it has shipped.
--
-- `ck_fpd_calls_source` (0007) is widened by one value, `officer`. The server
-- decides the source; no route accepts it. Dropped and re-added under the
-- same name, because MariaDB cannot alter a CHECK in place.

ALTER TABLE `fpd_calls` DROP CONSTRAINT IF EXISTS `ck_fpd_calls_source`;

ALTER TABLE `fpd_calls`
    ADD CONSTRAINT `ck_fpd_calls_source` CHECK (`source` IN
        ('dispatcher', 'phone', 'export', 'panic', 'alpr', 'officer'));
