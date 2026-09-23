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

--- The access record type.
---
--- `spaning` rather than `bolo`: the hit this module raises is labelled
--- `spaning` in `query/service.lua`, and the record type a confirmation is
--- checked against has to be the one the hit names, or the confirmation log
--- points at the wrong register.
local SPANING <const> = 'spaning'

--- Adds the derived fields a screen needs.
local function decorate(row, now)
    row.live = service.isLive(row, now)
    row.banner = service.bannerFor(row)
    row.needsConfirmation = service.needsConfirmation(row)

    return row
end

--- Known associates of a spaning's person target, through the intel
--- module's own association mapping (spec 10, 0025) -- the same tie
--- `IntelPerson.svelte` shows on the subject's own record, surfaced here so
--- an officer reading a lookout for "this person" is told who else to
--- expect without opening a second screen.
---
--- Silently empty rather than refused when the session cannot read the
--- intel register at all: this is *extra* context on a record the officer
--- is already cleared to read via `spaning.view`, not a promise that every
--- person-target lookout has one, and it must never surface intelligence a
--- reader who lacks `intel.person.view` could not otherwise open (invariant
--- 4) -- the same "empty list, not a refusal" the vehicle-registry search on
--- `IntelPerson.svelte` already takes when the reverse permission is
--- missing.
local function knownAssociatesFor(session, row)
    if row.targetKind ~= 'person' or not row.targetId then return {} end
    if not FredPD.Core.perms.satisfies(session.permissions, 'intel.person.view') then return {} end

    local intel = FredPD.Repo.intel
    local subject = intel.byMasterPersonId(session.agencyId, row.targetId)
    if not subject then return {} end

    return intel.associatesForPerson(subject.id)
end

route.define({
    name = 'spaning.list',
    perm = 'spaning.view',
    schema = 'SpaningList',
    handler = function(session, input)
        local now = os.time()

        local found, nextCursor = repo.list(session.agencyId, {
            targetKind = input.targetKind,
            priority = input.priority,
            includeResolved = input.includeResolved,
        }, input.limit or 50, input.cursor)

        -- Decorated *before* the filter, so the loop never writes fields onto
        -- a 4.5 stub. A stub carries three fields and no more by design
        -- (`Access.stub` builds it rather than redacting a row), and a
        -- decorator that reaches it is how the next field somebody adds to
        -- this loop becomes a leak.
        for index = 1, #found do decorate(found[index], now) end

        local rows = access.filterSearch(session, SPANING, found)

        return { spaningsuppdrag = rows, nextCursor = nextCursor }
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

        return {
            spaning = decorate(allowed, os.time()),
            knownAssociates = knownAssociatesFor(session, allowed),
        }
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
        -- Read before write, the same as `spaning.get`. Without it an officer
        -- holding `spaning.create` but not the clearance could close a lookout
        -- above it, and the `not_found` versus `conflict` split told them the
        -- record was there (4.5, invariant 11).
        local row = repo.byId(input.id, session.agencyId)
        if not row then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

        if not access.read(session, SPANING, row) then
            return route.refuse(FredPD.ErrorCode.RESTRICTED)
        end

        -- The ground is a locale key the NUI renders with `t()`, so it is
        -- checked here rather than merely bounded by the schema.
        if input.grund ~= nil and not service.isAvslutsgrund(input.grund) then
            return route.refuse(FredPD.ErrorCode.INVALID, { grund = 'not_a_key' })
        end

        if repo.resolve(row.id, session.agencyId, session.discordId,
                        input.grund, input.version) == 0 then
            return route.refuse(FredPD.ErrorCode.CONFLICT)
        end

        return { id = row.id }
    end,
})
