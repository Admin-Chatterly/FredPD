--- Brottskatalog routes (spec 7.10).
---
--- The catalogue is read by everyone who can write a record and edited by
--- almost nobody. That asymmetry is the whole permission design here:
---
---   * **`brott.list`** needs only `rms.brott.view`, which every group that can
---     write an anmälan holds. A charging screen that could not read the
---     catalogue would be a charging screen with no offences in it.
---   * **`brott.create` and `brott.version`** need `admin.brott.edit` and are
---     marked `sensitive`, so a stale Discord snapshot cannot be used to edit
---     the legal basis of the department's records (spec 4.2). Editing a
---     straffskala is an administrative act with consequences in court, not a
---     data-entry convenience.
---
--- There is no delete route, and no update route. 7.10's versioning rule --
--- "a change never alters past records" -- is not enforceable by convention, so
--- the only write paths that exist are ones that preserve it: add a version,
--- or retire a code. See `repo.lua`.

local route = FredPD.Core.route
local repo = FredPD.Repo.brott
local service = FredPD.Modules.brott

route.define({
    name = 'brott.list',
    perm = 'rms.brott.view',
    schema = 'BrottList',
    handler = function(session, _input)
        -- Scoped to the session's agency on the server, never by a field the
        -- client sent (invariant 4).
        local rows = repo.current(session.agencyId)

        -- The citation is derived rather than stored, so there is one
        -- definition of the format and busted tests it. Computed here rather
        -- than in the NUI for the same reason: two implementations of
        -- `BrB 8:1` drift, and the one on the client is the one nobody tests.
        for index = 1, #rows do
            rows[index].citation = service.citation(rows[index])
        end

        return { brott = rows }
    end,
})

route.define({
    name = 'brott.versions',
    perm = 'rms.brott.view',
    schema = 'BrottVersions',
    handler = function(session, input)
        local code = service.normalizeCode(input.code)
        if not code then return route.refuse(FredPD.ErrorCode.INVALID, { code = 'required' }) end

        local rows = repo.versions(code, session.agencyId)
        if #rows == 0 then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

        for index = 1, #rows do
            rows[index].citation = service.citation(rows[index])
        end

        return { versions = rows }
    end,
})

--- The gemensam straffskala for a set of charges (BrB 26:2).
---
--- Computed on the server rather than in the NUI, and not because the NUI could
--- not add numbers: this is the figure an officer reads off the screen and
--- repeats to a prosecutor, so it has to come from the implementation busted
--- tests, against catalogue rows the server fetched, rather than from whatever
--- spans a client happened to be holding.
route.define({
    name = 'brott.straffskala',
    perm = 'rms.brott.view',
    schema = 'BrottStraffskala',
    handler = function(session, input)
        -- Duplicates survive this: three counts of one offence is three
        -- entries, and BrB 26:2 is computed over counts (see `parseIds`).
        local ids, reason = service.parseIds(input.brottIds, 25)
        if not ids then return route.refuse(FredPD.ErrorCode.INVALID, { brottIds = reason }) end

        local rows = repo.byIds(ids, session.agencyId)

        -- One row per count, in the order the charges were given. Nil when an
        -- id has no catalogue row -- another agency's id, or a typo -- which
        -- would otherwise be dropped from the calculation and produce a span
        -- that is too low with nothing on screen to say so.
        local charges = service.expandCharges(ids, rows)
        if not charges then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND, { brottIds = 'unknown' })
        end

        local skalor = {}
        for index = 1, #charges do
            local skala = service.straffskala(charges[index])

            -- A catalogue row that is not a valid span is a corrupt row, not a
            -- bad request. Refusing is better than computing around it.
            if not skala then return route.refuse(FredPD.ErrorCode.INTERNAL) end

            skalor[index] = skala
        end

        local gemensam = service.gemensamStraffskala(skalor)
        if not gemensam then return route.refuse(FredPD.ErrorCode.INVALID, { brottIds = 'empty' }) end

        return { straffskala = gemensam, brott = rows }
    end,
})

route.define({
    name = 'brott.create',
    perm = 'admin.brott.edit',
    schema = 'BrottCreate',
    writes = true,
    sensitive = true,
    audit = 'brott.created',
    subjectType = 'brott',
    auditDetail = function(input)
        return { code = input.code, grad = input.grad }
    end,
    handler = function(session, input)
        local err, fields = service.validate(input)
        if err then return route.refuse(err, fields) end

        input.code = service.normalizeCode(input.code)

        -- A code that is already in the catalogue takes a new version, not a
        -- second current row: `uq_fpd_brott_current` would refuse the insert
        -- anyway, and refusing here says which route to use instead.
        if repo.byCode(input.code, session.agencyId) then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { code = 'exists' })
        end

        return { id = repo.create(input, session.agencyId, session.discordId) }
    end,
})

route.define({
    name = 'brott.version',
    perm = 'admin.brott.edit',
    schema = 'BrottCreate',
    writes = true,
    sensitive = true,
    audit = 'brott.versioned',
    subjectType = 'brott',
    auditDetail = function(input)
        return { code = input.code, grad = input.grad }
    end,
    handler = function(session, input)
        local err, fields = service.validate(input)
        if err then return route.refuse(err, fields) end

        input.code = service.normalizeCode(input.code)

        local current = repo.byCode(input.code, session.agencyId)
        if not current then return route.refuse(FredPD.ErrorCode.NOT_FOUND, { code = 'unknown' }) end

        if not repo.createVersion(input, session.agencyId, session.discordId) then
            return route.refuse(FredPD.ErrorCode.CONFLICT)
        end

        return { code = input.code, supersededVersion = current.version }
    end,
})

route.define({
    name = 'brott.retire',
    perm = 'admin.brott.edit',
    schema = 'BrottVersions',
    writes = true,
    sensitive = true,
    audit = 'brott.retired',
    subjectType = 'brott',
    handler = function(session, input)
        local code = service.normalizeCode(input.code)
        if not code then return route.refuse(FredPD.ErrorCode.INVALID, { code = 'required' }) end

        if repo.supersede(code, session.agencyId) == 0 then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND, { code = 'unknown' })
        end

        return { code = code }
    end,
})
