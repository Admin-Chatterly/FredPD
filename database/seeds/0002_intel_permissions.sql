-- Intelligence permission groups (spec 10, Appendix B and C).
--
-- A separate seed rather than an edit to 0001: seeds are re-runnable, but
-- keeping each milestone's grants in its own file makes it obvious what a
-- given module added, and lets a server that does not run intelligence simply
-- not apply this one.
--
-- As in 0001, no Discord role is mapped here. Role ids belong to your guild,
-- and that mapping is made in the MDT (spec 7.30).
--
-- The three groups mirror the RUE roles in Appendix C. What separates them is
-- not how much they can read -- an analyst reads the whole register -- but two
-- specific powers: seeing where protected intelligence came from, and
-- destroying records.

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

INSERT IGNORE INTO `fpd_group_permissions` (`group_key`, `permission`) VALUES
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
