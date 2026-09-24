--- Personnel routes (spec 7.22-7.24).
---
--- The disciplinary file goes through `access.read`/`access.filterSearch` the
--- same way a restricted åtal does in `court/routes.lua`: `ia_case` ships
--- stubbed to everyone until an operator configures who may see it (spec
--- 4.5), and this module does not loosen that default.
---
--- Shift start/end is self-service and reads `session.officerId` rather than
--- an id in `input` -- an officer clocking on is not a fact another officer's
--- client gets to assert (the same reasoning `session.discordId` gets for
--- every write in this suite).

local route = FredPD.Core.route
local repo = FredPD.Repo.personnel
local service = FredPD.Modules.personnel
local access = FredPD.Repo.access

local DISCIPLINE <const> = 'ia_case'

-- -----------------------------------------------------------------------------
-- Roster
-- -----------------------------------------------------------------------------

route.define({
    name = 'personnel.roster.list',
    perm = 'personnel.roster.view',
    schema = 'PersonnelRosterList',
    handler = function(session, input)
        return { officers = repo.roster(session.agencyId, {
            active = input.active,
            division = input.division,
        }, input.limit or 100) }
    end,
})

route.define({
    name = 'personnel.roster.get',
    perm = 'personnel.roster.view',
    schema = 'PersonnelRosterGet',
    handler = function(session, input)
        local row = repo.byId(input.id, session.agencyId)
        if not row then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

        row.discordRoles = repo.discordRoles(row.discordId)
        row.equipment = repo.equipmentFor(row.id, session.agencyId)
        row.certifications = repo.certificationsFor(row.id, session.agencyId)
        row.shiftLog = repo.shiftLog(row.id, session.agencyId, 20)
        row.openShift = repo.openShift(row.id, session.agencyId)
        -- Resolved for display, the same reason `ordningsbot.get` attaches
        -- the tariff a citation cites rather than leaving the NUI to
        -- re-fetch a bare id.
        row.loadout = repo.officerLoadout(row.id, session.agencyId)

        return { officer = row }
    end,
})

route.define({
    name = 'personnel.roster.update',
    perm = 'personnel.roster.edit',
    schema = 'PersonnelRosterUpdate',
    writes = true,
    sensitive = true,
    audit = 'personnel.roster.updated',
    subjectType = 'person',
    auditDetail = function(input) return { id = input.id, callsign = input.callsign } end,
    handler = function(session, input)
        local err, fields = service.validateRosterUpdate(input)
        if err then return route.refuse(err, fields) end

        if not repo.byId(input.id, session.agencyId) then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        if input.callsign and repo.callsignTaken(input.callsign, session.agencyId, input.id) then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { callsign = 'exists' })
        end

        repo.updateRoster(input.id, session.agencyId, input)

        if input.callsign then
            FredPD.Core.session.setCallsign(input.id, input.callsign)
        end

        return { id = input.id }
    end,
})

-- -----------------------------------------------------------------------------
-- Shift log
-- -----------------------------------------------------------------------------

route.define({
    name = 'personnel.shift.start',
    perm = 'personnel.shift.own',
    schema = 'PersonnelShiftStart',
    writes = true,
    handler = function(session)
        if not session.officerId then return route.refuse(FredPD.ErrorCode.FORBIDDEN) end

        if repo.openShift(session.officerId, session.agencyId) then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { _input = 'already_on_shift' })
        end

        local id = repo.startShift(session.officerId, session.agencyId, session.callsign)

        return { id = id }
    end,
})

route.define({
    name = 'personnel.shift.end',
    perm = 'personnel.shift.own',
    schema = 'PersonnelShiftEnd',
    writes = true,
    handler = function(session)
        if not session.officerId then return route.refuse(FredPD.ErrorCode.FORBIDDEN) end

        local open = repo.openShift(session.officerId, session.agencyId)
        if not open then return route.refuse(FredPD.ErrorCode.CONFLICT, { _input = 'not_on_shift' }) end

        repo.endShift(open.id, session.officerId, session.agencyId)

        return { id = open.id }
    end,
})

-- -----------------------------------------------------------------------------
-- Equipment
-- -----------------------------------------------------------------------------

route.define({
    name = 'personnel.equipment.assign',
    perm = 'personnel.equipment.manage',
    schema = 'PersonnelEquipmentAssign',
    writes = true,
    sensitive = true,
    audit = 'personnel.equipment.assigned',
    subjectType = 'person',
    auditDetail = function(input) return { officerId = input.officerId, itemKey = input.itemKey } end,
    handler = function(session, input)
        local err, fields = service.validateEquipmentAssign(input)
        if err then return route.refuse(err, fields) end

        if not repo.byId(input.officerId, session.agencyId) then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        -- `personnel.equipment.manage` is the base grant; some items are
        -- gated further behind a specific Discord role or group (0027) --
        -- checked against the *issuing* session, never the officer
        -- receiving the item.
        local gate = repo.issueGateFor(session.agencyId, 'equipment', input.itemKey)
        local holdsDiscordRole, satisfiesGroup = repo.gateChecksFor(session.agencyId, session.discordId)
        if not service.gatingSatisfied(gate, holdsDiscordRole, satisfiesGroup) then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { itemKey = 'gated' })
        end

        local id = repo.assignEquipment(input.officerId, session, input)

        return { id = id }
    end,
})

route.define({
    name = 'personnel.equipment.return',
    perm = 'personnel.equipment.manage',
    schema = 'PersonnelEquipmentReturn',
    writes = true,
    sensitive = true,
    audit = 'personnel.equipment.returned',
    subjectType = 'person',
    auditDetail = function(input) return { id = input.id } end,
    handler = function(session, input)
        if repo.returnEquipment(input.id, input.officerId, session.agencyId) == 0 then
            return route.refuse(FredPD.ErrorCode.CONFLICT)
        end

        return { id = input.id }
    end,
})

-- -----------------------------------------------------------------------------
-- Issue gates (0027): a Discord role or permission group required to issue
-- one equipment item or certification key, beyond `personnel.equipment.manage`/
-- `personnel.certification.manage` themselves. Configuring a gate is gated
-- on `personnel.equipment.manage` regardless of which kind it names -- the
-- same supervisor tier that already hand-issues both.
-- -----------------------------------------------------------------------------

route.define({
    name = 'personnel.issueGate.list',
    perm = 'personnel.equipment.manage',
    schema = 'PersonnelIssueGateList',
    handler = function(session)
        return { gates = repo.issueGates(session.agencyId) }
    end,
})

route.define({
    name = 'personnel.issueGate.set',
    perm = 'personnel.equipment.manage',
    schema = 'PersonnelIssueGateSet',
    writes = true,
    sensitive = true,
    audit = 'personnel.issueGate.set',
    subjectType = 'person',
    auditDetail = function(input)
        return {
            kind = input.kind, itemKey = input.itemKey,
            requiredGroup = input.requiredGroup, requiredDiscordRole = input.requiredDiscordRole,
        }
    end,
    handler = function(session, input)
        local err, fields = service.validateIssueGateSet(input)
        if err then return route.refuse(err, fields) end

        if input.requiredGroup and not FredPD.Core.perms.permissionsOf(input.requiredGroup) then
            return route.refuse(FredPD.ErrorCode.INVALID, { requiredGroup = 'unknown' })
        end

        repo.setIssueGate(
            session.agencyId, input.kind, input.itemKey,
            input.requiredGroup, input.requiredDiscordRole, session.discordId)

        return { kind = input.kind, itemKey = input.itemKey }
    end,
})

route.define({
    name = 'personnel.issueGate.clear',
    perm = 'personnel.equipment.manage',
    schema = 'PersonnelIssueGateClear',
    writes = true,
    sensitive = true,
    audit = 'personnel.issueGate.cleared',
    subjectType = 'person',
    auditDetail = function(input) return { kind = input.kind, itemKey = input.itemKey } end,
    handler = function(session, input)
        if not service.isIssueKind(input.kind) then
            return route.refuse(FredPD.ErrorCode.INVALID, { kind = 'not_a_key' })
        end

        if repo.clearIssueGate(session.agencyId, input.kind, input.itemKey) == 0 then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        return { kind = input.kind, itemKey = input.itemKey }
    end,
})

-- -----------------------------------------------------------------------------
-- Loadouts (0026): a named equipment set, and duty-based auto issue/return
--
-- Assignment and issuing are the same gate that already covers hand-issuing
-- one item (`personnel.equipment.manage`): defining a kit and handing it out
-- one radio at a time are the same authority. Issuing and returning the
-- items themselves happen off `fredpd:dutyChanged`
-- (`server/modules/personnel/events.lua`), never a route -- an officer's own
-- duty state is a fact the server observes, not one a client asserts.
-- -----------------------------------------------------------------------------

route.define({
    name = 'personnel.loadout.list',
    perm = 'personnel.equipment.manage',
    schema = 'PersonnelLoadoutList',
    handler = function(session)
        local loadouts = repo.loadouts(session.agencyId)

        for index = 1, #loadouts do
            loadouts[index].itemKeys = repo.loadoutItemKeys(loadouts[index].id)
        end

        return { loadouts = loadouts }
    end,
})

route.define({
    name = 'personnel.loadout.create',
    perm = 'personnel.equipment.manage',
    schema = 'PersonnelLoadoutCreate',
    writes = true,
    sensitive = true,
    audit = 'personnel.loadout.created',
    subjectType = 'person',
    auditDetail = function(input) return { name = input.name, itemKeys = input.itemKeys } end,
    handler = function(session, input)
        local err, fields = service.validateLoadoutCreate(input)
        if err then return route.refuse(err, fields) end

        local id = repo.createLoadout(session.agencyId, input.name, input.itemKeys, session.discordId)
        if not id then return route.refuse(FredPD.ErrorCode.CONFLICT, { name = 'exists' }) end

        return { id = id }
    end,
})

route.define({
    name = 'personnel.loadout.delete',
    perm = 'personnel.equipment.manage',
    schema = 'PersonnelLoadoutDelete',
    writes = true,
    sensitive = true,
    audit = 'personnel.loadout.deleted',
    subjectType = 'person',
    auditDetail = function(input) return { id = input.id } end,
    handler = function(session, input)
        if repo.deleteLoadout(input.id, session.agencyId) == 0 then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        return { id = input.id }
    end,
})

route.define({
    name = 'personnel.officer.setLoadout',
    perm = 'personnel.equipment.manage',
    schema = 'PersonnelOfficerSetLoadout',
    writes = true,
    sensitive = true,
    audit = 'personnel.officer.loadoutSet',
    subjectType = 'person',
    auditDetail = function(input) return { officerId = input.officerId, loadoutId = input.loadoutId } end,
    handler = function(session, input)
        local err, fields = service.validateSetLoadout(input)
        if err then return route.refuse(err, fields) end

        if not repo.byId(input.officerId, session.agencyId) then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        if input.loadoutId and not repo.loadoutById(input.loadoutId, session.agencyId) then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND, { loadoutId = 'unknown' })
        end

        -- Existence is already checked above, so an affected count of zero
        -- here means only "already set to this", the same no-op
        -- `Repo.updateRoster` accepts as success rather than a conflict.
        repo.setOfficerLoadout(input.officerId, session.agencyId, input.loadoutId)

        return { officerId = input.officerId }
    end,
})

-- -----------------------------------------------------------------------------
-- Certifications
-- -----------------------------------------------------------------------------

route.define({
    name = 'personnel.certification.issue',
    perm = 'personnel.certification.manage',
    schema = 'PersonnelCertificationIssue',
    writes = true,
    sensitive = true,
    audit = 'personnel.certification.issued',
    subjectType = 'person',
    auditDetail = function(input) return { officerId = input.officerId, certKey = input.certKey } end,
    handler = function(session, input)
        local err, fields = service.validateCertificationIssue(input)
        if err then return route.refuse(err, fields) end

        if not repo.byId(input.officerId, session.agencyId) then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        -- See `personnel.equipment.assign`'s identical check: some
        -- certifications are gated further behind a specific Discord role
        -- or group (0027), checked against the issuer, not the recipient.
        local gate = repo.issueGateFor(session.agencyId, 'certification', input.certKey)
        local holdsDiscordRole, satisfiesGroup = repo.gateChecksFor(session.agencyId, session.discordId)
        if not service.gatingSatisfied(gate, holdsDiscordRole, satisfiesGroup) then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { certKey = 'gated' })
        end

        local id = repo.issueCertification(input.officerId, session, input)

        return { id = id }
    end,
})

route.define({
    name = 'personnel.certification.revoke',
    perm = 'personnel.certification.manage',
    schema = 'PersonnelCertificationRevoke',
    writes = true,
    sensitive = true,
    audit = 'personnel.certification.revoked',
    subjectType = 'person',
    auditDetail = function(input) return { id = input.id } end,
    handler = function(session, input)
        if repo.revokeCertification(input.id, input.officerId, session.agencyId, session.discordId) == 0 then
            return route.refuse(FredPD.ErrorCode.CONFLICT)
        end

        return { id = input.id }
    end,
})

-- -----------------------------------------------------------------------------
-- The disciplinary file
-- -----------------------------------------------------------------------------

route.define({
    name = 'personnel.discipline.list',
    perm = 'personnel.discipline.view',
    schema = 'PersonnelDisciplineList',
    sensitive = true,
    audit = 'personnel.discipline.read',
    subjectType = DISCIPLINE,
    auditDetail = function(input) return { officerId = input.officerId } end,
    handler = function(session, input)
        local found = repo.disciplineForOfficer(input.officerId, session.agencyId)

        return { cases = access.filterSearch(session, DISCIPLINE, found) }
    end,
})

route.define({
    name = 'personnel.discipline.open',
    perm = 'personnel.discipline.manage',
    schema = 'PersonnelDisciplineOpen',
    writes = true,
    sensitive = true,
    audit = 'personnel.discipline.opened',
    subjectType = DISCIPLINE,
    auditDetail = function(input) return { officerId = input.officerId, category = input.category } end,
    handler = function(session, input)
        local err, fields = service.validateDisciplineOpen(input)
        if err then return route.refuse(err, fields) end

        if not repo.byId(input.officerId, session.agencyId) then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        local row = repo.openDiscipline(input.officerId, session, input)
        if not row then return route.refuse(FredPD.ErrorCode.INTERNAL) end

        return { id = row.id, number = row.number }
    end,
})

route.define({
    name = 'personnel.discipline.close',
    perm = 'personnel.discipline.manage',
    schema = 'PersonnelDisciplineClose',
    writes = true,
    sensitive = true,
    audit = 'personnel.discipline.closed',
    subjectType = DISCIPLINE,
    auditDetail = function(input) return { id = input.id, outcomeKey = input.outcomeKey } end,
    handler = function(session, input)
        local err, fields = service.validateDisciplineClose(input)
        if err then return route.refuse(err, fields) end

        local row = repo.disciplineById(input.id, session.agencyId)
        if not row then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

        if not access.read(session, DISCIPLINE, row) then
            return route.refuse(FredPD.ErrorCode.RESTRICTED)
        end

        if repo.closeDiscipline(input.id, session.agencyId, input, input.version) == 0 then
            return route.refuse(FredPD.ErrorCode.CONFLICT)
        end

        return { id = input.id }
    end,
})

-- -----------------------------------------------------------------------------
-- Discord role actions (ADR-022, amending ADR-010)
--
-- Hire, promote, demote and dismiss, as a Discord role change the gateway
-- makes with a bot of its own. FredPD never writes a permission: the change
-- goes to Discord, and comes back through the read sync like any other
-- (`discord.refreshOne`, then every open session re-derives its grants).
-- Both routes are `sensitive` (refused on a stale snapshot, spec 4.2),
-- audited with the reason, and rate-limited; `service.roleChange` is the
-- guard on who may ask for what.
-- -----------------------------------------------------------------------------

local function roleConfig()
    return FredPD.Config.server.roleActions or {}
end

--- Role actions are offered only when this server and the gateway both say
--- so; either one off is "not here", never an error to retry.
local function roleActionsOn()
    -- And FredPD must be reading Discord: without the read sync nothing here
    -- can weigh a role or a target, and every guard below would be a no-op.
    return roleConfig().enabled == true and FredPD.Bridge.gateway.service.isEnabled()
        and FredPD.Core.discord.enabled()
end

--- Discord's own names for the managed roles, read at most every ten
--- minutes: the names are Discord's data, not text FredPD owns (invariant 6).
local roleNames = { at = 0, names = {} }

local function namesOfRoles()
    if os.time() - roleNames.at < 600 then return roleNames.names end

    local names = {}
    for _, role in ipairs(FredPD.Core.discord.guildRoles() or {}) do names[role.id] = role.name end

    roleNames = { at = os.time(), names = names }
    return names
end

--- The managed roles as a screen shows them, and which this member holds.
local function rolesFor(held)
    local holds = {}
    for _, id in ipairs(held or {}) do holds[tostring(id)] = true end

    local names = namesOfRoles()
    local out = {}
    for id, role in pairs(service.manageableRoles(roleConfig().roles)) do
        out[#out + 1] = { id = id, kind = role.kind, name = names[id] or id, held = holds[id] == true }
    end

    table.sort(out, function(a, b)
        if a.kind ~= b.kind then return a.kind == 'hire' end
        return a.name < b.name
    end)

    return out
end

route.define({
    name = 'personnel.roles.get',
    perm = 'personnel.roster.view',
    schema = 'PersonnelRolesGet',
    handler = function(session, input)
        -- No officer: the roles a new hire could be given, held by nobody.
        local officer = nil
        if input.id then
            officer = repo.byId(input.id, session.agencyId)
            if not officer then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end
        end

        if not roleActionsOn() then return { enabled = false, roles = {} } end

        local perms = FredPD.Core.perms
        return {
            enabled = true,
            roles = rolesFor(officer and repo.discordRoles(officer.discordId) or {}),
            self = officer ~= nil and officer.discordId == session.discordId,
            may = {
                hire = perms.satisfies(session.permissions, 'personnel.hire'),
                promote = perms.satisfies(session.permissions, 'personnel.promote'),
            },
        }
    end,
})

--- One role change, for either route. `kind` is the route's own: the hire
--- route never touches a rank and the rank route never touches the hire role.
--- Every role request that does not end in a change is audited here, with
--- what was asked and why it stopped: the wrapper's own refusal row carries
--- only the error code, and an attempt to demote the commander is exactly
--- what internal affairs needs to read in full (invariant 11).
local function auditRole(session, outcome, input, targetDiscordId, extra)
    local detail = {
        officerId = input.officerId,
        targetDiscordId = targetDiscordId,
        roleId = input.roleId,
        grant = input.grant,
        reason = input.reason,
    }
    for key, value in pairs(extra or {}) do detail[key] = value end

    FredPD.Core.audit.write({
        action = 'personnel.role.attempted',
        discordId = session.discordId,
        agencyId = session.agencyId,
        subjectType = 'officer',
        subjectId = input.officerId and tostring(input.officerId) or nil,
        outcome = outcome,
        detail = detail,
    })
end

--- One role change, for either route. `kind` is the route's own: the hire
--- route never touches a rank and the rank route never touches the hire role.
local function changeRole(session, input, kind)
    local function refuse(code, why, targetDiscordId, extra)
        extra = extra or {}
        extra.why = why
        auditRole(session, 'denied', input, targetDiscordId, extra)
        return route.refuse(code, { roleId = why })
    end

    if not roleActionsOn() then return refuse(FredPD.ErrorCode.CONFLICT, 'role_actions_off') end

    -- A session on the ESX-job fallback holds no Discord grant at all; it
    -- never drives a Discord role (invariant 2).
    if session.localFallback then return refuse(FredPD.ErrorCode.FORBIDDEN, 'needs_permission') end

    local role = service.manageableRoles(roleConfig().roles)[input.roleId]
    if not role or role.kind ~= kind then return refuse(FredPD.ErrorCode.FORBIDDEN, 'not_allowed') end

    local perms = FredPD.Core.perms

    -- A role worth something in another agency is weighed only in this one
    -- below, so it is not one this screen hands out.
    for _, agencyId in ipairs(perms.agenciesMapping(role.id)) do
        if agencyId ~= session.agencyId then return refuse(FredPD.ErrorCode.FORBIDDEN, 'not_allowed') end
    end

    -- The target: an officer on this agency's roster, or -- only to hire --
    -- a Discord member who is not on it yet.
    local targetDiscordId, officerId
    if input.officerId then
        local officer = repo.byId(input.officerId, session.agencyId)
        if not officer then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end
        targetDiscordId, officerId = officer.discordId, officer.id
    elseif input.discordId and kind == 'hire' and input.grant then
        if not tostring(input.discordId):match('^%d+$') then
            return route.refuse(FredPD.ErrorCode.INVALID, { discordId = 'not_snowflake' })
        end
        targetDiscordId = input.discordId
    else
        return route.refuse(FredPD.ErrorCode.INVALID, { officerId = 'required' })
    end

    -- The target is weighed on what Discord says now, not on the last sync:
    -- a role given to them in Discord minutes ago is what makes them the
    -- actor's superior. A target with no fresh row is refused -- except a new
    -- hire by Discord id, who has nothing to outrank anybody with, and whose
    -- role is capped by "worth no more than the actor holds" regardless.
    FredPD.Core.discord.refreshOne(targetDiscordId, true)
    local _, age = perms.memberRoles(targetDiscordId)
    local newHire = input.discordId ~= nil and input.officerId == nil
    if (age == nil and not newHire)
        or (age ~= nil and age > FredPD.Config.server.discord.sensitiveStaleAfterSeconds)
    then
        return refuse(FredPD.ErrorCode.CONFLICT, 'target_stale', targetDiscordId)
    end

    -- A superuser's Discord roles are not a non-superuser's to take (9b).
    local targetPermissions = perms.effectiveFor(targetDiscordId, session.agencyId)
    if repo.isSuperuser(targetDiscordId) then targetPermissions = { ['*'] = true } end

    local ok, why = service.roleChange({
        role = role,
        grant = input.grant,
        actorDiscordId = session.discordId,
        targetDiscordId = targetDiscordId,
        actorPermissions = session.permissions,
        targetPermissions = targetPermissions,
        rolePermissions = perms.ofRoles({ role.id }, session.agencyId),
        superuser = session.superuser == true,
        satisfies = perms.satisfies,
        missing = perms.missing,
    })
    if not ok then return refuse(FredPD.ErrorCode.FORBIDDEN, why, targetDiscordId) end

    local reason = ('%s (%s): %s'):format(
        session.callsign or session.name or '', session.discordId, input.reason)

    local changed, err = FredPD.Bridge.gateway.service.setDiscordRole(
        targetDiscordId, role.id, input.grant and 'add' or 'remove', reason)
    if not changed then
        -- The gateway's own words for "not switched on there" and "that is
        -- not a request I understand", in this screen's vocabulary.
        if err == 'disabled' then err = 'role_actions_off' end
        if err == 'invalid' then err = 'discord_error' end

        -- No answer is not a no: Discord may have made the change after the
        -- gateway gave up waiting. Audited as unknown, and read back.
        if err == 'discord_unreachable' or err == 'gateway_unavailable' then
            auditRole(session, 'error', input, targetDiscordId, { why = err, result = 'unknown' })
            pcall(FredPD.Core.discord.refreshOne, targetDiscordId, true)
            return route.refuse(FredPD.ErrorCode.CONFLICT, { roleId = err })
        end

        return refuse(FredPD.ErrorCode.CONFLICT, err, targetDiscordId)
    end

    -- Discord is the truth: read it back rather than assume, then let every
    -- open session -- the target's included -- re-derive what it may do. A
    -- failure here must not turn a change Discord made into an error with no
    -- audit row: the change stands, and the next sync picks it up.
    local refreshed = pcall(function()
        FredPD.Core.discord.refreshOne(targetDiscordId, true)
        FredPD.Core.session.refreshAll()
    end)
    if not refreshed then print('[fredpd] role actions: the change was made; the read-back failed and waits for the next sync') end

    return {
        id = officerId or 0,
        roleId = role.id,
        kind = role.kind,
        grant = input.grant,
        targetDiscordId = targetDiscordId,
    }
end

local function roleAuditDetail(input, result)
    return {
        officerId = input.officerId,
        targetDiscordId = result.targetDiscordId,
        roleId = input.roleId,
        kind = result.kind,
        grant = input.grant,
        reason = input.reason,
    }
end

route.define({
    name = 'personnel.roles.hire',
    perm = 'personnel.hire',
    schema = 'PersonnelRoleChange',
    writes = true,
    sensitive = true,
    limit = { per = 10, window = 60 },
    audit = 'personnel.role.changed',
    subjectType = 'officer',
    auditDetail = roleAuditDetail,
    handler = function(session, input) return changeRole(session, input, 'hire') end,
})

route.define({
    name = 'personnel.roles.rank',
    perm = 'personnel.promote',
    schema = 'PersonnelRoleChange',
    writes = true,
    sensitive = true,
    limit = { per = 10, window = 60 },
    audit = 'personnel.role.changed',
    subjectType = 'officer',
    auditDetail = roleAuditDetail,
    handler = function(session, input) return changeRole(session, input, 'rank') end,
})

--- For another module that needs to know whether an officer carries an item
--- (7.19: a body-worn camera is the `bodycam` they were issued).
FredPD.Modules.personnelHolds = function(officerId, agencyId, itemKey)
    return repo.holds(officerId, agencyId, itemKey)
end
