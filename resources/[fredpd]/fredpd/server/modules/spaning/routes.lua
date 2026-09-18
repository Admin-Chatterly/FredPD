--- Spaningsuppdrag routes (spec 7.13).
---
--- Raising a lookout is **patrol work**, unlike issuing an efterlysning. That
--- is the permission difference between the two modules and it follows from
--- what they are: an efterlysning is a prosecutor's decision that somebody be
--- detained, and a spaningsuppdrag is an officer saying "look for this van".
--- A department where the second needed command approval would simply not use
--- it, and the sightings would live in the radio traffic where nothing can
--- search them.
---
--- What patrol may *not* do is make a lookout as loud as an efterlysning.
--- `Spaning.bannerFor` caps it at `alert`, and priority 1 is the only thing
--- that reaches even that.

local route = FredPD.Core.route
local repo = FredPD.Repo.spaning
local service = FredPD.Modules.spaning
local access = FredPD.Repo.access
local accessRules = FredPD.Modules.access

--- The access record type. `bolo` is already in the access module's allowlist.
local SPANING <const> = 'bolo'

--- Adds the derived fields a screen needs.
local function decorate(row, now)
    row.live = service.isLive(row, now)
    row.banner = service.bannerFor(row)
    row.needsConfirmation = service.needsConfirmation(row)

    return row
end

route.define({
    name = 'spaning.list',
    perm = 'spaning.view',
    schema = 'SpaningList',
    handler = function(session, input)
        local now = os.time()

        local rows = access.filterSearch(session, SPANING, repo.list(session.agencyId, {
            targetKind = input.targetKind,
            priority = input.priority,
            includeResolved = input.includeResolved,
        }, input.limit or 50))

        for index = 1, #rows do decorate(rows[index], now) end

        return { spaningsuppdrag = rows }
    end,
})

route.define({
    name = 'spaning.get',
    perm = 'spaning.view',
    schema = 'SpaningGet',
    handler = function(session, input)
        local row = repo.byId(input.id, session.agencyId)
        if not row then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

        local allowed = access.read(session, SPANING, row)
        if not allowed then return route.refuse(FredPD.ErrorCode.RESTRICTED) end

        return { spaning = decorate(allowed, os.time()) }
    end,
})

route.define({
    name = 'spaning.create',
    perm = 'spaning.create',
    schema = 'SpaningCreate',
    writes = true,
    audit = 'spaning.created',
    subjectType = SPANING,
    auditDetail = function(input)
        return {
            targetKind = input.targetKind,
            targetId = input.targetId,
            priority = input.priority,
        }
    end,
    handler = function(session, input)
        local err, fields = service.validate(input)
        if err then return route.refuse(err, fields) end

        if not accessRules.canClassify(access.reader(session), input.classification) then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { classification = 'over_clearance' })
        end

        local seconds = input.validSeconds or service.DEFAULT_VALIDITY

        local row = repo.create(input, session, seconds)
        if not row then return route.refuse(FredPD.ErrorCode.INTERNAL) end

        return { id = row.id, number = row.number, spaning = decorate(row, os.time()) }
    end,
})

route.define({
    name = 'spaning.resolve',
    perm = 'spaning.create',
    schema = 'SpaningResolve',
    writes = true,
    audit = 'spaning.resolved',
    subjectType = SPANING,
    handler = function(session, input)
        local row = repo.byId(input.id, session.agencyId)
        if not row then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

        if repo.resolve(row.id, session.agencyId, session.discordId,
                        input.grund, input.version) == 0 then
            return route.refuse(FredPD.ErrorCode.CONFLICT)
        end

        return { id = row.id }
    end,
})
