-- Default permission groups (spec 4.3, Appendix B and C).
--
-- Seeds ship with the product and must be re-runnable without duplicating rows,
-- so every statement here is an upsert or an INSERT IGNORE.
--
-- These are the *bundles*. Which Discord role grants which bundle is not seeded:
-- role ids are specific to your guild, and that mapping is edited in the MDT
-- (spec 7.30). A fresh install therefore grants nobody anything until an
-- administrator maps the first role, which is the correct default.
--
-- Groups here cover what exists today (M1). Later milestones add their own.

INSERT INTO `fpd_permission_groups` (`key`, `name`, `inherits`, `description`) VALUES
    ('patrol_basic', 'Patrol (trainee)', NULL,
     'A trainee: read the MDT and use the internal channel, nothing that changes a record.'),
    ('patrol',       'Patrol',           'patrol_basic',
     'A patrol officer: motor pool, queries, the internal channel.'),
    ('supervisor',   'Supervisor',       'patrol',
     'A field supervisor: everything patrol has, plus oversight.'),
    ('command',      'Command',          'supervisor',
     'Command staff.'),
    ('dispatch',     'Dispatch',         'patrol_basic',
     'A dispatcher: the CAD console and the internal channel.'),
    ('admin',        'FredPD administration', NULL,
     'Configures FredPD. Deliberately does NOT inherit patrol: administering the system is not the same as being cleared to read records.')
ON DUPLICATE KEY UPDATE
    -- `VALUES(col)` rather than MySQL 8's `AS new` row alias: MariaDB does not
    -- implement the alias form, and the spec targets MariaDB 11.4 (spec 3.3).
    `name`        = VALUES(`name`),
    `inherits`    = VALUES(`inherits`),
    `description` = VALUES(`description`);

-- -----------------------------------------------------------------------------
-- Group -> permission keys
-- -----------------------------------------------------------------------------

INSERT IGNORE INTO `fpd_group_permissions` (`group_key`, `permission`) VALUES
    -- A trainee can look and can talk, and that is all.
    ('patrol_basic', 'page.records'),
    ('patrol_basic', 'page.comms'),
    ('patrol_basic', 'comms.pdchat.send'),
    ('patrol_basic', 'comms.pdchat.view'),

    -- Patrol adds the motor pool and the vehicle they need to do the job.
    ('patrol', 'garage.vehicle.draw'),
    ('patrol', 'garage.vehicle.return'),
    ('patrol', 'query.person.run'),
    ('patrol', 'query.vehicle.run'),

    -- A supervisor sees the whole department's traffic, not just their agency's.
    ('supervisor', 'comms.pdchat.all'),

    -- Command staff read the audit log.
    ('command', 'admin.audit.view'),
    ('command', 'page.personnel'),

    -- Dispatch.
    ('dispatch', 'page.dispatch'),
    ('dispatch', 'cad.console.open'),

    -- Administration configures the system: permissions, placements, fleet.
    -- Note what is absent: no record clearance, no compartments. An admin who
    -- needs to read records is granted a records group as well, deliberately
    -- and visibly (spec 4.3, Appendix C).
    ('admin', 'page.admin'),
    ('admin', 'admin.permissions.edit'),
    ('admin', 'admin.placement.edit'),
    ('admin', 'admin.branding.edit'),
    ('admin', 'admin.audit.view'),
    ('admin', 'garage.fleet.edit');
