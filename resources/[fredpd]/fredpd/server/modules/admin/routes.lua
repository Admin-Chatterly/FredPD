--- Administration routes: the Discord role map (spec 4.3, 7.30).
---
--- This is what makes permissions configurable in game. An administrator maps a
--- Discord role id to a permission group from the MDT, and it takes effect on
--- the next reload — no restart, no config file.
---
--- Invariant 2 is unchanged by any of this. Discord roles remain the only
--- permission source; what is editable here is the *mapping*, not the source.

local route = FredPD.Core.route
local db = FredPD.Core.db

--- A Discord snowflake is digits only. The schema already bounds the length;
--- this rejects the shape, so a role name pasted into the id field fails here
--- rather than silently never matching anyone.
local function isSnowflake(value)
    return value:match('^%d+$') ~= nil
end

route.define({
    name = 'admin.rolemap.list',
    perm = 'admin.permissions.edit',
    schema = 'RoleMapList',
    handler = function(session, _input)
        local mappings = db.query(
            [[SELECT m.id, m.discord_role_id AS discordRoleId, m.discord_role_name AS discordRoleName,
                     m.group_key AS groupKey, m.agency_id AS agencyId, g.name AS groupName
                FROM fpd_role_map m
                JOIN fpd_permission_groups g ON g.`key` = m.group_key
               WHERE m.agency_id = ?
               ORDER BY m.discord_role_name, m.group_key]],
            { session.agencyId }
        )

        local groups = db.query(
            'SELECT `key`, name, inherits, description FROM fpd_permission_groups ORDER BY `key`'
        )

        -- How stale the Discord snapshot is, so the screen can say whether what
        -- it is showing is current (spec 4.2).
        local snapshotAge = db.scalar(
            'SELECT TIMESTAMPDIFF(SECOND, MAX(synced_at), NOW()) FROM fpd_discord_members'
        )

        return { mappings = mappings, groups = groups, snapshotAgeSeconds = snapshotAge }
    end,
})

route.define({
    name = 'admin.rolemap.create',
    perm = 'admin.permissions.edit',
    schema = 'RoleMapCreate',
    writes = true,
    -- Granting permissions on a stale snapshot is exactly the case spec 4.2
    -- blocks: the roles we would be mapping against may already be wrong.
    sensitive = true,
    audit = 'rolemap.created',
    subjectType = 'role_map',
    auditDetail = function(input)
        return { discordRoleId = input.discordRoleId, groupKey = input.groupKey, agencyId = input.agencyId }
    end,
    handler = function(session, input)
        if not isSnowflake(input.discordRoleId) then
            return route.refuse(FredPD.ErrorCode.INVALID, { discordRoleId = 'not_snowflake' })
        end

        -- An administrator configures their own agency, not somebody else's.
        if input.agencyId ~= session.agencyId then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN)
        end

        local granted = FredPD.Core.perms.permissionsOf(input.groupKey)
        if not granted then
            return route.refuse(FredPD.ErrorCode.INVALID, { groupKey = 'unknown' })
        end

        -- An administrator may not hand out more than they hold. Without this,
        -- `admin.permissions.edit` is self-escalation in one call: map a role
        -- you already have to any group, including one carrying the record
        -- clearance the seed deliberately keeps out of `admin` (spec 4.3,
        -- Appendix C). Auditing it afterwards is not the same as preventing it.
        local missing = FredPD.Core.perms.missing(granted, session.permissions)
        if #missing > 0 then
            FredPD.Core.audit.denied(
                session, 'admin.rolemap.create', 'escalation:' .. missing[1], 'role_map'
            )
            return route.refuse(FredPD.ErrorCode.FORBIDDEN)
        end

        local existing = db.single(
            [[SELECT id FROM fpd_role_map
               WHERE discord_role_id = ? AND group_key = ? AND agency_id = ?]],
            { input.discordRoleId, input.groupKey, input.agencyId }
        )

        if existing then
            return route.refuse(FredPD.ErrorCode.CONFLICT)
        end

        local id = db.insert(
            [[INSERT INTO fpd_role_map (discord_role_id, discord_role_name, group_key, agency_id, created_by)
              VALUES (?, ?, ?, ?, ?)]],
            {
                input.discordRoleId,
                input.discordRoleName,
                input.groupKey,
                input.agencyId,
                session.discordId,
            }
        )

        -- Recompute, then push the new module list to everyone already online.
        -- Granting a permission that only applies after a reconnect would make
        -- the editor feel broken.
        FredPD.Core.perms.reload()
        FredPD.Core.session.refreshAll()

        return { id = id }
    end,
})

route.define({
    name = 'admin.rolemap.delete',
    perm = 'admin.permissions.edit',
    schema = 'RoleMapDelete',
    writes = true,
    sensitive = true,
    audit = 'rolemap.deleted',
    subjectType = 'role_map',
    handler = function(session, input)
        local existing = db.single(
            'SELECT id, agency_id AS agencyId, discord_role_id AS discordRoleId, group_key AS groupKey FROM fpd_role_map WHERE id = ?',
            { input.id }
        )

        if not existing then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        if existing.agencyId ~= session.agencyId then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN)
        end

        db.execute('DELETE FROM fpd_role_map WHERE id = ?', { input.id })

        -- Revocation must be immediate: an open MDT loses its pages now, not on
        -- the officer's next reconnect (spec 4.2).
        FredPD.Core.perms.reload()
        FredPD.Core.session.refreshAll()

        return { id = input.id }
    end,
})

--- The session's own view of itself, for the NUI shell.
route.define({
    name = 'session.get',
    perm = 'page.records',
    handler = function(session, _input)
        return {
            callsign = session.callsign,
            name = session.name,
            agencyId = session.agencyId,
            agencyName = FredPD.Core.agencies.nameOf(session.agencyId),
            onDuty = FredPD.Bridge.policejob.isOnDuty(session.src),
            modules = FredPD.Core.session.allowedModules(session),
            permissionsStale = FredPD.Core.session.isStale(session),
        }
    end,
})

-- =============================================================================
-- The permission group editor (spec 7.30, 4.3)
--
-- The role map above answers "which Discord role gets this bundle?". This
-- answers "what is in the bundle?" -- which is the more dangerous half, and the
-- reason every write here runs the same escalation check.
--
-- The rule, in one sentence: an administrator may never author a group worth
-- more than what they hold themselves. Without it, `admin.groups.edit` is a
-- one-call escalation to anything: create `harmless`, map your own role to it
-- (the role map lets you, because at that moment it grants nothing), then edit
-- `harmless` to carry `records.breakglass`. Checking creation but not editing
-- would leave exactly that path open, so both are checked, and both are checked
-- against the *resulting* group including everything it inherits.
--
-- Two consequences that are deliberate rather than accidental:
--
--   * An administrator cannot edit a group that already carries more than they
--     hold -- not even to rename it. Being able to reach into `intel_command`
--     at all is the thing being denied; a rename today is an edit tomorrow.
--   * Groups are global, not per-agency (`fpd_permission_groups` has no
--     `agency_id`). An edit here changes what the bundle means everywhere, and
--     is checked against the permissions the editor holds in their own agency.
-- =============================================================================

--- The seeded group that configures FredPD. It may be edited -- that is the
--- point of the editor -- but it may not be renamed, deleted, or stripped of
--- the keys that make the editor reachable. Locking yourself out of the
--- permission editor means editing the database by hand to get back in.
local PROTECTED_GROUP <const> = 'admin'

--- What `admin` must keep granting, however it is edited.
local ADMIN_FLOOR <const> = { 'page.admin', 'admin.permissions.edit', 'admin.groups.edit' }

--- The permission catalogue (Appendix B).
---
--- `FredPD.Core.route.names()` lists route *names*; there is no equivalent for
--- the permission each route declares, so the catalogue cannot be derived from
--- the registry today. It is this constant plus whatever `fpd_group_permissions`
--- already contains, so a key an operator granted before it was catalogued
--- still appears in the editor rather than silently vanishing from it.
---
--- The templated entries in Appendix B -- `rms.report.view.<type>`,
--- `clearance.<level>`, `compartment.<name>` -- are patterns, not keys, and are
--- left out. The editor offers keys; a clearance is not one of them.
local PERMISSION_CATALOGUE <const> = {
    -- Pages
    'page.query', 'page.dispatch', 'page.records', 'page.evidence', 'page.lab',
    'page.intel', 'page.court', 'page.personnel', 'page.stats', 'page.admin', 'page.comms',

    -- Queries
    'query.person.run', 'query.vehicle.run', 'query.firearm.run', 'query.phone.run',
    'query.address.run', 'query.log.view',

    -- Records
    'rms.person.view', 'rms.person.edit', 'rms.person.photo.upload', 'rms.person.caution.edit',
    'rms.vehicle.view', 'rms.vehicle.edit', 'rms.vehicle.flag',
    'rms.firearm.view', 'rms.firearm.edit', 'rms.firearm.trace',
    'rms.location.view', 'rms.location.hazard.edit',

    -- Reports
    'rms.report.create', 'rms.report.edit.own', 'rms.report.submit',
    'rms.report.approve', 'rms.report.return', 'rms.report.void',

    -- Enforcement
    'rms.arrest.create', 'rms.citation.issue', 'rms.citation.void',
    'rms.bolo.create', 'rms.bolo.cancel', 'rms.bolo.view',
    'rms.fi.create', 'rms.stops.create',
    'rms.impound.create', 'rms.impound.release', 'rms.impound.hold.release',
    'rms.warrant.serve',

    -- Investigations
    'inv.case.create', 'inv.case.view', 'inv.case.edit', 'inv.case.assign', 'inv.case.close',

    -- Booking
    'booking.create', 'booking.biometrics.capture', 'booking.release',

    -- Court
    'court.warrant.request', 'court.warrant.review', 'court.warrant.recall',
    'court.referral.review', 'court.calendar.manage', 'court.disposition.enter',
    'court.discovery.issue', 'court.discovery.view', 'court.seal.order',
    'court.citation.adjudicate', 'court.sentence.calculate',

    -- Dispatch
    'cad.call.create', 'cad.call.dispatch', 'cad.call.self_assign', 'cad.call.clear',
    'cad.unit.manage', 'cad.broadcast', 'cad.console.open',
    'alpr.read.view', 'alpr.hotlist.manage',

    -- Forensics
    'forensics.scene.create', 'forensics.scene.release',
    'forensics.evidence.collect', 'forensics.tools.use',

    -- Property room
    'evidence.item.view', 'evidence.item.intake', 'evidence.item.transfer',
    'evidence.item.checkout', 'evidence.item.release', 'evidence.item.dispose',
    'evidence.item.reseal', 'evidence.audit.run',

    -- Lab
    'lab.request.create', 'lab.queue.view', 'lab.analysis.perform',
    'lab.analysis.review', 'lab.report.release',

    -- Surveillance
    'surv.phone.intercept', 'surv.radio.monitor', 'surv.device.deploy',
    'surv.device.listen', 'surv.tracker.deploy', 'surv.tracker.view', 'surv.log.view',

    -- Intelligence
    'intel.module.open', 'intel.report.create', 'intel.report.view', 'intel.report.edit',
    'intel.person.view', 'intel.person.edit', 'intel.person.merge',
    'intel.org.view', 'intel.org.edit', 'intel.case.view', 'intel.case.edit',
    'intel.evidence.add', 'intel.record.delete', 'intel.surveillance.log',
    'intel.source.view', 'intel.source.manage', 'intel.source.identity.view',
    'intel.operation.approve',

    -- Personnel
    'personnel.view', 'personnel.hire', 'personnel.promote', 'personnel.discipline',
    'personnel.equipment.assign', 'ia.case.view', 'ia.case.manage', 'uof.review',
    'policy.manage', 'policy.ack',

    -- Communications
    'comms.message.send', 'comms.bulletin.post',
    'comms.pdchat.send', 'comms.pdchat.view', 'comms.pdchat.all',

    -- Motor pool
    'garage.vehicle.draw', 'garage.vehicle.return', 'garage.fleet.edit',

    -- Statistics
    'stats.view', 'stats.export',

    -- Administration
    'admin.permissions.edit', 'admin.groups.edit', 'admin.penalcode.edit',
    'admin.codetables.edit', 'admin.branding.edit', 'admin.audit.view',
    'admin.retention.edit', 'admin.health.view', 'admin.placement.edit',

    -- Access
    'records.breakglass', 'fields.mental_health.view', 'fields.victim_address.view',
}

--- The only columns an update may write, each with the expression it is written
--- with. The column name comes from this table and never from input
--- (invariant 8), and `NULLIF(?, '')` is how a field is cleared: a `nil` in an
--- oxmysql values list silently shortens the list and shifts every placeholder
--- after it, so an empty string travels instead and MariaDB makes it NULL.
local GROUP_COLUMNS <const> = {
    { field = 'name', sql = '`name` = ?' },
    { field = 'inherits', sql = [[`inherits` = NULLIF(?, '')]] },
    { field = 'description', sql = [[`description` = NULLIF(?, '')]] },
}

--- A group key: lower-case, and safe to read back in a log line.
local function isGroupKey(value)
    return type(value) == 'string' and value:match('^[a-z][a-z0-9_]*$') ~= nil and #value <= 64
end

--- A permission key in Appendix B's shape: `<area>.<object>[.<action>]`.
---
--- A trailing `*` is allowed, because `Perms.satisfies` honours a wildcard in a
--- grant -- `records.*` covers everything beneath it. It is allowed only as the
--- last segment: `records.*.view` is a shape `satisfies` can never match, so
--- storing it would create a grant that looks powerful and does nothing. A bare
--- `*` is rejected for the same reason, and one segment on its own is not a key.
local function isPermissionKey(value)
    if type(value) ~= 'string' then return false end

    local length = #value
    if length == 0 or length > 128 then return false end
    if value:find('%.%.') or value:sub(1, 1) == '.' or value:sub(-1) == '.' then return false end

    local segments = {}
    for segment in value:gmatch('[^%.]+') do segments[#segments + 1] = segment end

    if #segments < 2 then return false end

    for index = 1, #segments do
        local segment = segments[index]

        if segment == '*' then
            if index ~= #segments then return false end
        elseif not segment:match('^[a-z][a-z0-9_]*$') then
            return false
        end
    end

    return true
end

--- A set's keys, sorted, so responses and audit entries are stable.
local function sortedKeys(set)
    local keys = {}
    for key in pairs(set) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

--- Cleans a permission list: whitespace stripped, lower-cased, de-duplicated.
--- @return table|nil permissions
--- @return string|nil the first entry that is not a permission key
local function normalizePermissions(list)
    local set = {}

    for index = 1, #list do
        local key = (list[index]:gsub('%s', '')):lower()

        if not isPermissionKey(key) then return nil, list[index] end

        set[key] = true
    end

    return sortedKeys(set), nil
end

--- Every group in the shape `Perms.expandGroup` wants: key -> { inherits, permissions }.
---
--- Read fresh rather than taken from the permission cache, because a write is
--- about to be judged against it and the cache is only as current as the last
--- reload.
local function loadGroupModel()
    local groups = {}

    local groupRows = db.query('SELECT `key`, `inherits` FROM fpd_permission_groups')
    for index = 1, #groupRows do
        groups[groupRows[index].key] = { inherits = groupRows[index].inherits, permissions = {} }
    end

    local permissionRows = db.query('SELECT `group_key`, `permission` FROM fpd_group_permissions')
    for index = 1, #permissionRows do
        local group = groups[permissionRows[index].group_key]
        if group then
            group.permissions[#group.permissions + 1] = permissionRows[index].permission
        end
    end

    return groups
end

--- True when following `inherits` from `key` leads back to `key`.
---
--- `Perms.expandGroup` survives a cycle, so this is not about crashing. It is
--- about not writing one: a cycle makes "what does this group grant?"
--- unanswerable by reading the row, which is the only way an administrator can
--- audit it.
local function inheritsCycle(groups, key)
    local seen = { [key] = true }
    local group = groups[key]
    local current = group and group.inherits or nil

    while current do
        if seen[current] then return true end

        seen[current] = true
        local parent = groups[current]
        current = parent and parent.inherits or nil
    end

    return false
end

--- A group's own permission keys, as stored.
local function ownPermissions(groupKey)
    local rows = db.query(
        'SELECT `permission` FROM fpd_group_permissions WHERE group_key = ? ORDER BY `permission`',
        { groupKey }
    )

    local permissions = {}
    for index = 1, #rows do permissions[index] = rows[index].permission end

    return permissions
end

--- Refuses when the group as proposed would grant more than the session holds.
---
--- `groups` is the whole model with the proposed change already applied, so
--- what is measured is the group as it would exist -- its own keys *and*
--- everything the inheritance chain adds -- rather than the fields that
--- happened to be in the request.
---
--- @return table|nil a refusal to return from the handler, or nil to proceed
local function refuseEscalation(session, action, groups, key)
    local granted = FredPD.Core.perms.expandGroup(key, groups)
    local missing = FredPD.Core.perms.missing(granted, session.permissions)

    if #missing == 0 then return nil end

    -- Named in the audit entry: "denied" on its own does not tell the next
    -- administrator which key the last one reached for.
    FredPD.Core.audit.denied(
        session, action, 'escalation:' .. missing[1], 'permission_group', key
    )

    return route.refuse(FredPD.ErrorCode.FORBIDDEN)
end

--- Statements that write a group's permission rows.
---
--- `replace` clears what is stored first, which is how an update writes: a
--- group has a few dozen keys, and a diff that goes wrong leaves behind a grant
--- nobody asked for. A create has nothing to clear.
local function permissionStatements(key, permissions, replace)
    local statements = {}

    if replace then
        statements[1] = { query = 'DELETE FROM fpd_group_permissions WHERE group_key = ?', values = { key } }
    end

    for index = 1, #permissions do
        statements[#statements + 1] = {
            query = 'INSERT IGNORE INTO fpd_group_permissions (group_key, permission) VALUES (?, ?)',
            values = { key, permissions[index] },
        }
    end

    return statements
end

--- Blank is not a value: a name of spaces is a missing name.
local function blank(value)
    return value == nil or value:match('^%s*$') ~= nil
end

--- Recompute, then push. A permission change that only lands on the next
--- reconnect makes the editor look broken and leaves a revoked officer holding
--- pages they no longer have (spec 4.2).
local function applied()
    FredPD.Core.perms.reload()
    FredPD.Core.session.refreshAll()
end

route.define({
    name = 'admin.group.list',
    perm = 'admin.groups.edit',
    schema = 'GroupList',
    -- A read, but marked like the writes beside it: the group model is the
    -- permission model, and reading it off a Discord snapshot nobody can vouch
    -- for is not a page anyone needs during an outage (spec 4.2).
    writes = true,
    sensitive = true,
    audit = 'group.listed',
    subjectType = 'permission_group',
    auditDetail = function(_input, result)
        return { count = #result.groups }
    end,
    handler = function(session, _input)
        local groups = loadGroupModel()

        local rows = db.query(
            [[SELECT g.`key`, g.name, g.inherits, g.description, g.created_at AS createdAt,
                     (SELECT COUNT(*) FROM fpd_permission_groups c WHERE c.inherits = g.`key`) AS childCount,
                     (SELECT COUNT(*) FROM fpd_role_map m WHERE m.group_key = g.`key`) AS roleMapCount,
                     (SELECT COUNT(*) FROM fpd_role_map m
                       WHERE m.group_key = g.`key` AND m.agency_id = ?) AS agencyRoleMapCount
                FROM fpd_permission_groups g
               ORDER BY g.`key`]],
            { session.agencyId }
        )

        for index = 1, #rows do
            local row = rows[index]
            local granted = FredPD.Core.perms.expandGroup(row.key, groups)

            row.permissions = ownPermissions(row.key)
            row.effective = sortedKeys(granted)

            -- What the editor may do with this group, decided here rather than
            -- in the UI (invariant 4). The UI greys the row out; the refusal
            -- that matters is the one on the write.
            row.locked = row.key == PROTECTED_GROUP
            row.editable = #FredPD.Core.perms.missing(granted, session.permissions) == 0
        end

        return { groups = rows }
    end,
})

route.define({
    name = 'admin.group.create',
    perm = 'admin.groups.edit',
    schema = 'GroupCreate',
    writes = true,
    sensitive = true,
    audit = 'group.created',
    subjectType = 'permission_group',
    auditDetail = function(input, result)
        return { key = input.key, inherits = input.inherits, permissions = result.permissions }
    end,
    handler = function(session, input)
        if not isGroupKey(input.key) then
            return route.refuse(FredPD.ErrorCode.INVALID, { key = 'not_group_key' })
        end

        if blank(input.name) then
            return route.refuse(FredPD.ErrorCode.INVALID, { name = 'required' })
        end

        local permissions = normalizePermissions(input.permissions)
        if not permissions then
            return route.refuse(FredPD.ErrorCode.INVALID, { permissions = 'not_permission_key' })
        end

        local groups = loadGroupModel()

        if groups[input.key] then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { key = 'exists' })
        end

        local inherits = input.inherits ~= '' and input.inherits or nil
        if inherits and not groups[inherits] then
            return route.refuse(FredPD.ErrorCode.INVALID, { inherits = 'unknown' })
        end

        groups[input.key] = { inherits = inherits, permissions = permissions }

        if inheritsCycle(groups, input.key) then
            return route.refuse(FredPD.ErrorCode.INVALID, { inherits = 'cycle' })
        end

        local refusal = refuseEscalation(session, 'admin.group.create', groups, input.key)
        if refusal then return refusal end

        local statements = {
            {
                query = [[INSERT INTO fpd_permission_groups (`key`, `name`, `inherits`, `description`)
                          VALUES (?, ?, NULLIF(?, ''), NULLIF(?, ''))]],
                values = { input.key, input.name, inherits or '', input.description or '' },
            },
        }

        local rows = permissionStatements(input.key, permissions, false)
        for index = 1, #rows do statements[#statements + 1] = rows[index] end

        if not db.transaction(statements) then
            return route.refuse(FredPD.ErrorCode.INTERNAL)
        end

        applied()

        -- `id` is the group's key: the table's primary key is the key, and the
        -- route layer reads `result.id` for the audit entry's subject.
        return { id = input.key, key = input.key, permissions = permissions }
    end,
})

route.define({
    name = 'admin.group.update',
    perm = 'admin.groups.edit',
    schema = 'GroupUpdate',
    writes = true,
    sensitive = true,
    audit = 'group.updated',
    subjectType = 'permission_group',
    auditDetail = function(input, result)
        return { key = input.key, added = result.added, removed = result.removed }
    end,
    handler = function(session, input)
        if not isGroupKey(input.key) then
            return route.refuse(FredPD.ErrorCode.INVALID, { key = 'not_group_key' })
        end

        local existing = db.single(
            'SELECT `key`, `name`, `inherits`, `description` FROM fpd_permission_groups WHERE `key` = ?',
            { input.key }
        )

        if not existing then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        if input.name ~= nil and blank(input.name) then
            return route.refuse(FredPD.ErrorCode.INVALID, { name = 'required' })
        end

        -- What the group grants today, kept for the audit entry's diff and used
        -- as the proposal when the request does not touch permissions at all.
        local current = ownPermissions(input.key)
        local permissions = current

        if input.permissions then
            local cleaned = normalizePermissions(input.permissions)
            if not cleaned then
                return route.refuse(FredPD.ErrorCode.INVALID, { permissions = 'not_permission_key' })
            end

            permissions = cleaned
        end

        local inherits = existing.inherits
        if input.inherits ~= nil then
            inherits = input.inherits ~= '' and input.inherits or nil
        end

        local groups = loadGroupModel()

        if inherits and not groups[inherits] then
            return route.refuse(FredPD.ErrorCode.INVALID, { inherits = 'unknown' })
        end

        if inherits == input.key then
            return route.refuse(FredPD.ErrorCode.INVALID, { inherits = 'cycle' })
        end

        groups[input.key] = { inherits = inherits, permissions = permissions }

        if inheritsCycle(groups, input.key) then
            return route.refuse(FredPD.ErrorCode.INVALID, { inherits = 'cycle' })
        end

        -- Measured against the group as it would be, not against what changed:
        -- an edit that leaves a permission in place is still an administrator
        -- signing their name under the whole bundle.
        local refusal = refuseEscalation(session, 'admin.group.update', groups, input.key)
        if refusal then return refusal end

        if input.key == PROTECTED_GROUP then
            if input.name and input.name ~= existing.name then
                return route.refuse(FredPD.ErrorCode.FORBIDDEN, { name = 'protected' })
            end

            -- The floor is checked against the expanded set, so `admin` may
            -- move these keys into a group it inherits from -- what is refused
            -- is the edit that leaves nobody able to reach the editor at all.
            local granted = FredPD.Core.perms.expandGroup(input.key, groups)

            for index = 1, #ADMIN_FLOOR do
                if not FredPD.Core.perms.satisfies(granted, ADMIN_FLOOR[index]) then
                    return route.refuse(FredPD.ErrorCode.FORBIDDEN, { permissions = 'would_lock_out' })
                end
            end
        end

        local sets, values = {}, {}

        for index = 1, #GROUP_COLUMNS do
            local column = GROUP_COLUMNS[index]

            if input[column.field] ~= nil then
                sets[#sets + 1] = column.sql
                values[#values + 1] = input[column.field]
            end
        end

        local statements = {}

        if #sets > 0 then
            values[#values + 1] = input.key
            statements[1] = {
                query = ('UPDATE fpd_permission_groups SET %s WHERE `key` = ?')
                    :format(table.concat(sets, ', ')),
                values = values,
            }
        end

        if input.permissions then
            local rows = permissionStatements(input.key, permissions, true)
            for index = 1, #rows do statements[#statements + 1] = rows[index] end
        end

        if #statements == 0 then
            return route.refuse(FredPD.ErrorCode.INVALID, { _input = 'nothing_to_change' })
        end

        if not db.transaction(statements) then
            return route.refuse(FredPD.ErrorCode.INTERNAL)
        end

        applied()

        -- What actually changed, for the audit entry. A permission change is the
        -- one case where the diff *is* the record: "group updated" tells the
        -- next administrator nothing they can act on.
        local before, after = {}, {}
        for index = 1, #current do before[current[index]] = true end
        for index = 1, #permissions do after[permissions[index]] = true end

        local added, removed = {}, {}
        for key in pairs(after) do if not before[key] then added[#added + 1] = key end end
        for key in pairs(before) do if not after[key] then removed[#removed + 1] = key end end
        table.sort(added)
        table.sort(removed)

        return {
            id = input.key,
            key = input.key,
            permissions = permissions,
            added = added,
            removed = removed,
        }
    end,
})

route.define({
    name = 'admin.group.delete',
    perm = 'admin.groups.edit',
    schema = 'GroupDelete',
    writes = true,
    sensitive = true,
    audit = 'group.deleted',
    subjectType = 'permission_group',
    auditDetail = function(input, result)
        return { key = input.key, permissions = result.permissions }
    end,
    handler = function(session, input)
        if not isGroupKey(input.key) then
            return route.refuse(FredPD.ErrorCode.INVALID, { key = 'not_group_key' })
        end

        if input.key == PROTECTED_GROUP then
            FredPD.Core.audit.denied(
                session, 'admin.group.delete', 'protected_group', 'permission_group', input.key
            )
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { key = 'protected' })
        end

        local groups = loadGroupModel()
        if not groups[input.key] then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        -- Deleting a bundle you are not cleared to author destroys clearance
        -- for everyone who holds it. It cannot escalate, but "I could not grant
        -- it, so I removed it" is not an administrator's call to make either.
        local refusal = refuseEscalation(session, 'admin.group.delete', groups, input.key)
        if refusal then return refusal end

        -- The two foreign keys onto this row would both resolve this silently:
        -- `fpd_permission_groups.inherits` is ON DELETE SET NULL, so a child
        -- group would quietly lose everything it inherited, and
        -- `fpd_role_map.group_key` is ON DELETE CASCADE, so every mapping onto
        -- it would disappear with it. Both are refusals, not side effects.
        local children = db.scalar(
            'SELECT COUNT(*) FROM fpd_permission_groups WHERE inherits = ?', { input.key }
        )

        if children and children > 0 then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { inherits = 'inherited_by_groups' })
        end

        local mapped = db.scalar(
            'SELECT COUNT(*) FROM fpd_role_map WHERE group_key = ?', { input.key }
        )

        if mapped and mapped > 0 then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { key = 'mapped_to_roles' })
        end

        local permissions = ownPermissions(input.key)

        if db.execute('DELETE FROM fpd_permission_groups WHERE `key` = ?', { input.key }) == 0 then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        applied()

        return { id = input.key, key = input.key, permissions = permissions }
    end,
})

route.define({
    name = 'admin.permission.list',
    perm = 'admin.groups.edit',
    schema = 'PermissionList',
    writes = true,
    sensitive = true,
    audit = 'permission.listed',
    auditDetail = function(_input, result)
        return { count = #result.permissions }
    end,
    handler = function(session, _input)
        local catalogue = {}

        for index = 1, #PERMISSION_CATALOGUE do
            catalogue[PERMISSION_CATALOGUE[index]] = 0
        end

        -- Anything already granted, catalogued or not. A key that exists in the
        -- data but not in Appendix B is the interesting case: the editor has to
        -- show it, or an administrator would remove it by saving a form that
        -- never offered it back.
        local rows = db.query(
            [[SELECT `permission`, COUNT(*) AS groupCount
                FROM fpd_group_permissions
               GROUP BY `permission`]]
        )

        for index = 1, #rows do
            catalogue[rows[index].permission] = rows[index].groupCount
        end

        local permissions = {}

        for _, key in ipairs(sortedKeys(catalogue)) do
            permissions[#permissions + 1] = {
                key = key,
                -- The first segment, so the editor can group the list without
                -- parsing keys itself.
                area = key:match('^([^%.]+)') or key,
                groupCount = catalogue[key],
                -- Whether this session could put the key in a group at all. The
                -- write refuses it either way; showing it up front is the
                -- difference between a disabled checkbox and a mystery error.
                grantable = FredPD.Core.perms.satisfies(session.permissions, key),
            }
        end

        return { permissions = permissions }
    end,
})
