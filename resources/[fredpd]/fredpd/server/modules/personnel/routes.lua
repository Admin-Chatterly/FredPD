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
    auditDetail = function(input) return { id = input.id } end,
    handler = function(session, input)
        local err, fields = service.validateRosterUpdate(input)
        if err then return route.refuse(err, fields) end

        if not repo.byId(input.id, session.agencyId) then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        repo.updateRoster(input.id, session.agencyId, input)

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
