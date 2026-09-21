--- Placement routes (spec 3.10, 7.30).
---
--- Editing where a module opens is an administrative act: it needs
--- `admin.placement.edit`, it is audited, and it is marked sensitive so a stale
--- Discord snapshot cannot be used to move a terminal (spec 4.2).

local route = FredPD.Core.route
local repo = FredPD.Repo.placements
local service = FredPD.Modules.placements

route.define({
    name = 'placement.list',
    perm = 'admin.placement.edit',
    schema = 'PlacementList',
    handler = function(session, _input)
        -- Scoped on the server, not by the field the client sent: `agencyId` in
        -- the input is a filter request, never an authorisation (invariant 4).
        return { placements = repo.forAgency(session.agencyId) }
    end,
})

route.define({
    name = 'placement.create',
    perm = 'admin.placement.edit',
    schema = 'PlacementCreate',
    writes = true,
    sensitive = true,
    audit = 'placement.created',
    subjectType = 'placement',
    auditDetail = function(input)
        return { kind = input.kind, interaction = input.interaction, model = input.model }
    end,
    handler = function(session, input)
        local err, fields = service.validate(input)
        if err then return route.refuse(err, fields) end

        -- An administrator creating an agency-scoped placement may only scope it
        -- to their own agency; scoping it to another one would be configuring a
        -- department they do not belong to.
        if input.agencyId and input.agencyId ~= session.agencyId then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN)
        end

        local id = repo.create(input, session.discordId)
        FredPD.Core.placements.reload()

        return { id = id }
    end,
})

route.define({
    name = 'placement.update',
    perm = 'admin.placement.edit',
    schema = 'PlacementUpdate',
    writes = true,
    sensitive = true,
    audit = 'placement.updated',
    subjectType = 'placement',
    auditDetail = function(input)
        local changed = {}
        for field in pairs(input) do
            if field ~= 'id' then changed[#changed + 1] = field end
        end
        table.sort(changed)
        return { fields = changed }
    end,
    handler = function(session, input)
        local existing = repo.byId(input.id)
        if not existing then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

        -- A shared placement (NULL agency, spec 3.10) is editable by any
        -- agency's administrator, deliberately: somebody has to be able to
        -- manage it, and there is no shared-administrator role. It is the one
        -- cross-agency write in the module, and it is audited like the rest.
        local usable = service.isUsableBy(existing, session.agencyId)
        if not usable and existing.agencyId ~= nil then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN)
        end

        -- Validate the placement as it will be *after* the change, not as it
        -- arrived: a partial update that drops the model from a prop placement
        -- is just as broken as creating one without it.
        local merged = {}
        for key, value in pairs(existing) do merged[key] = value end
        for key, value in pairs(input) do merged[key] = value end

        local err, fields = service.validate(merged)
        if err then return route.refuse(err, fields) end

        repo.update(input.id, input)
        FredPD.Core.placements.reload()

        return { id = input.id }
    end,
})

route.define({
    name = 'placement.delete',
    perm = 'admin.placement.edit',
    schema = 'PlacementDelete',
    writes = true,
    sensitive = true,
    audit = 'placement.deleted',
    subjectType = 'placement',
    handler = function(session, input)
        local existing = repo.byId(input.id)
        if not existing then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

        local usable = service.isUsableBy(existing, session.agencyId)
        if not usable and existing.agencyId ~= nil then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN)
        end

        repo.delete(input.id)
        FredPD.Core.placements.reload()

        return { id = input.id }
    end,
})
