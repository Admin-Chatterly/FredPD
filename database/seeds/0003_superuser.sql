-- 0003_superuser.sql
--
-- The superuser permission group: one group, one grant, and the grant is the
-- literal wildcard '*' -- everything, in every namespace, forever -- rather
-- than an enumerated list of every permission key that exists today.
--
-- A list would go stale. It already has, once: the group editor's own
-- `PERMISSION_CATALOGUE` (`server/modules/admin/routes.lua`) was hand-written
-- against an earlier shape of the product and is missing entire modules'
-- worth of keys real routes check today (personnel, booking, impound,
-- ordningsbot, the `page.*` keys for all four), while offering a page of keys
-- (`personnel.hire`, `rms.report.*`, ...) that nothing checks any more. A
-- migration that copied that list in would carry the same drift into
-- `superuser`, and being append-only, could never be corrected -- only ever
-- patched around in a later file. `Perms.satisfies` honouring a bare '*'
-- (spec `server/core/perms.lua`) is what lets one row stay correct without
-- ever being edited again.
--
-- This group inherits nothing and is inherited by nothing. It is not a rank
-- above `command` or `admin` -- it is a recovery tool, granted only by the
-- console command `fredpd_superuser` (`server/modules/admin/superuser.lua`),
-- which has no in-game counterpart at all. Nothing in the ordinary role map or
-- group editor can reach it on its own: mapping a role to a group the caller
-- does not already hold is refused (the same escalation guard
-- `admin.rolemap.create` and `admin.group.*` already enforce), and nobody
-- reaches `'*'` except through this seed or through already holding it.
--
-- Invariant 8: append-only. Never edit this file once it has shipped.

INSERT INTO `fpd_permission_groups` (`key`, `name`, `inherits`, `description`) VALUES
    ('superuser', 'Superuser',        NULL,
     'Every permission that exists, in every namespace. Granted only by the console command fredpd_superuser -- never through the role map or the group editor, and never inherited. A recovery tool, not a rank.')
ON DUPLICATE KEY UPDATE
    `name`        = VALUES(`name`),
    `inherits`    = VALUES(`inherits`),
    `description` = VALUES(`description`);

INSERT IGNORE INTO `fpd_group_permissions` (`group_key`, `permission`) VALUES
    ('superuser', '*');
