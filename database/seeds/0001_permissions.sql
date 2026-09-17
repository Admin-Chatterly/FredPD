-- Default permission groups (spec 4.3, Appendix B and C).
--
-- Seeds ship with the product and must be re-runnable without duplicating rows,
-- so every statement here is an upsert or an INSERT IGNORE.
--
-- These are the *bundles*. Which Discord role grants which bundle is not seeded:
-- role ids are specific to your guild, and that mapping is edited in the MDT
-- (spec 7.30). A fresh install therefore grants nobody anything until an
-- administrator maps the first role, which is the correct default -- and it is
-- also why a group you do not want is harmless: an unmapped group grants
-- nobody anything.
--
-- Groups here cover what exists today (M1 and the intelligence register).
-- Later milestones add their own.

-- -----------------------------------------------------------------------------
-- Platform groups
-- -----------------------------------------------------------------------------

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
-- Intelligence groups (spec 10, Appendix C)
--
-- The three mirror the RUE roles. What separates them is not how much they can
-- read -- an analyst reads the whole register -- but two specific powers:
-- seeing where protected intelligence came from, and destroying records.
--
-- A second statement rather than more rows above, because `inherits` is a
-- foreign key onto this same table: the platform groups must exist before
-- anything can inherit from them, and keeping the two sets apart makes the
-- dependency obvious.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Evidence, property and lab groups (spec 8)
--
-- Three roles rather than one, because section 8's whole point is that custody
-- passes between people who are accountable separately. The officer who
-- collects, the officer who stores and the analyst who tests are different
-- jobs, and a chain of custody where they are the same person proves nothing.
-- -----------------------------------------------------------------------------

INSERT INTO `fpd_permission_groups` (`key`, `name`, `inherits`, `description`) VALUES
    ('evidence_tech', 'Crime scene technician', NULL,
     'Creates and processes scenes, collects evidence, uses forensic tools.'),
    ('property_officer', 'Property room officer', NULL,
     'Takes evidence into the property room, moves it, checks it in and out.'),
    ('lab_analyst', 'Forensic analyst', NULL,
     'Works the lab queue and performs analyses. Cannot release a report alone.'),
    ('lab_supervisor', 'Forensic supervisor', 'lab_analyst',
     'An analyst who may also technically review another analyst''s work and release the report.')
ON DUPLICATE KEY UPDATE
    `name`        = VALUES(`name`),
    `inherits`    = VALUES(`inherits`),
    `description` = VALUES(`description`);

INSERT INTO `fpd_permission_groups` (`key`, `name`, `inherits`, `description`) VALUES
    ('intel_analyst', 'Intelligence analyst', NULL,
     'Reads and writes the intelligence register. Cannot see protected sources and cannot delete.'),
    ('intel_handler', 'Source handler',       'intel_analyst',
     'An analyst who may also see where protected intelligence came from, and merge duplicate records.'),
    ('intel_command', 'Intelligence command', 'intel_handler',
     'A handler who may also delete records from the register.')
ON DUPLICATE KEY UPDATE
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
    ('admin', 'garage.fleet.edit'),

    -- The crime scene technician (8.4). Collecting is a specialist job: a
    -- patrol officer who picks a casing up off the ground has not collected
    -- evidence, they have contaminated a scene.
    ('evidence_tech', 'page.evidence'),
    ('evidence_tech', 'forensics.scene.create'),
    ('evidence_tech', 'forensics.scene.release'),
    ('evidence_tech', 'forensics.evidence.collect'),
    ('evidence_tech', 'forensics.tools.use'),
    ('evidence_tech', 'evidence.item.view'),

    -- The property room (8.6). Note what is separate: intake and disposal are
    -- not the same grant, because destroying evidence should be a decision
    -- somebody is named for.
    ('property_officer', 'page.evidence'),
    ('property_officer', 'evidence.item.view'),
    ('property_officer', 'evidence.item.intake'),
    ('property_officer', 'evidence.item.transfer'),
    ('property_officer', 'evidence.item.checkout'),
    ('property_officer', 'evidence.item.reseal'),
    ('property_officer', 'evidence.audit.run'),

    -- The lab (8.7).
    ('lab_analyst', 'page.lab'),
    ('lab_analyst', 'evidence.item.view'),
    ('lab_analyst', 'lab.request.create'),
    ('lab_analyst', 'lab.queue.view'),
    ('lab_analyst', 'lab.analysis.perform'),

    -- Technical review by a second analyst before release (8.7). Held apart
    -- from performing the analysis on purpose: reviewing your own work is not
    -- a review.
    ('lab_supervisor', 'lab.analysis.review'),
    ('lab_supervisor', 'lab.report.release'),

    -- Command signs off on releasing and disposing of evidence.
    ('command', 'evidence.item.view'),
    ('command', 'evidence.item.release'),
    ('command', 'evidence.item.dispose'),

    -- The analyst: the whole register, read and write.
    ('intel_analyst', 'page.intel'),
    ('intel_analyst', 'intel.module.open'),
    ('intel_analyst', 'intel.person.view'),
    ('intel_analyst', 'intel.person.edit'),
    ('intel_analyst', 'intel.org.view'),
    ('intel_analyst', 'intel.org.edit'),
    ('intel_analyst', 'intel.case.view'),
    ('intel_analyst', 'intel.case.edit'),
    ('intel_analyst', 'intel.report.view'),
    ('intel_analyst', 'intel.report.create'),
    ('intel_analyst', 'intel.report.edit'),
    ('intel_analyst', 'intel.evidence.add'),

    -- The handler. `intel.source.view` is the one that matters: without it a
    -- note from an informant, a wiretap or surveillance is readable but its
    -- source is withheld. That distinction is the whole reason the group
    -- exists -- in PD-Span every account could see every source.
    ('intel_handler', 'intel.source.view'),
    ('intel_handler', 'intel.person.merge'),

    -- Command. Deletion is separated deliberately: intelligence is meant to
    -- outlive the record it hung on, and destroying it should be a decision
    -- somebody is named for.
    ('intel_command', 'intel.record.delete');
