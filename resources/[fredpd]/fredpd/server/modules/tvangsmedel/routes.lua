--- Tvångsmedel och efterlysning routes, and the spec 14 exports (7.12, 7.13).
---
--- The exports at the bottom of this file are the reason it is written the way
--- it is. `HasSearchWarrant` is called by `ox_doorlock` to decide whether to
--- open somebody's front door; it takes no session, answers a boolean, and must
--- never be wrong in the permissive direction. So it goes through
--- `Tvang.isValid` and `Tvang.authorisesEntry` -- the two functions busted
--- exercises -- and through nothing else.

local route = FredPD.Core.route
local repo = FredPD.Repo.tvangsmedel
local service = FredPD.Modules.tvangsmedel
local access = FredPD.Repo.access
local accessRules = FredPD.Modules.access

--- The access record type. `warrant` is already in the access module's
--- allowlist and is what a grant would be written against.
local TVANG <const> = 'warrant'

--- And a wanted notice gets its own, which is not the measure's.
---
--- Both used `warrant` at first. Access control is keyed `(record_type,
--- record_id)`, `fpd_tvangsmedel` and `fpd_efterlysning` have independent
--- auto-increment ids, and the two draw from the same counter -- so the ids
--- overlap from the first day and a grant written on husrannsakan #42 would
--- also open efterlysning #42. Permissive, and silent.
---
--- Fixed before any route writes a grant, which is the only window in which it
--- can be fixed without orphaning real ones. `query/service.lua` already
--- labelled these hits `efterlysning`, so the two halves of the codebase
--- disagreed about what record type this was.
local EFTERLYSNING <const> = 'efterlysning'

--- Which capacity this session decides in.
---
--- Derived from permissions, never sent. A `domare` grant outranks an
--- `aklagare` one for the same reason it does in the frihet module.
local function capacityOf(session)
    local perms = session.permissions

    if FredPD.Core.perms.satisfies(perms, 'tvang.decide.domare') then return 'domare' end
    if FredPD.Core.perms.satisfies(perms, 'tvang.decide.aklagare') then return 'aklagare' end

    return 'fu_ledare'
end

--- Reads a measure the session is allowed to see, or refuses.
---
--- `tvang.upphav` and `efterlysning.cancel` went straight from a repo read to
--- an UPDATE. An officer holding the write grant but not the clearance could
--- revoke a husrannsakan above it, and learned the record existed from the
--- `not_found` versus `conflict` split -- the disclosure 4.5 exists to prevent.
--- The restricted read went unaudited too (invariant 11).
local function readableTvang(session, id)
    local row = repo.byId(id, session.agencyId)
    if not row then return nil, route.refuse(FredPD.ErrorCode.NOT_FOUND) end

    local allowed = access.read(session, TVANG, row)
    if not allowed then return nil, route.refuse(FredPD.ErrorCode.RESTRICTED) end

    return allowed
end

--- The same, for a wanted notice, under its own record type.
local function readableEfterlysning(session, id)
    local row = repo.efterlysningById(id, session.agencyId)
    if not row then return nil, route.refuse(FredPD.ErrorCode.NOT_FOUND) end

    local allowed = access.read(session, EFTERLYSNING, row)
    if not allowed then return nil, route.refuse(FredPD.ErrorCode.RESTRICTED) end

    return allowed
end

-- -----------------------------------------------------------------------------
-- Tvångsmedel
-- -----------------------------------------------------------------------------

route.define({
    name = 'tvang.list',
    perm = 'tvang.view',
    schema = 'TvangList',
    handler = function(session, input)
        local now = os.time()

        local rows = access.filterSearch(session, TVANG, repo.list(session.agencyId, {
            kind = input.kind,
            fuId = input.fuId,
            liveOnly = input.liveOnly,
        }, input.limit or 50))

        for index = 1, #rows do
            rows[index].live = service.isValid(rows[index], now)
        end

        return { tvangsmedel = rows }
    end,
})

route.define({
    name = 'tvang.get',
    perm = 'tvang.view',
    schema = 'TvangGet',
    handler = function(session, input)
        local row = repo.byId(input.id, session.agencyId)
        if not row then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

        local allowed = access.read(session, TVANG, row)
        if not allowed then return route.refuse(FredPD.ErrorCode.RESTRICTED) end

        local live, why = service.isValid(allowed, os.time())
        allowed.live = live
        allowed.notLiveBecause = why

        return { tvangsmedel = allowed }
    end,
})

route.define({
    name = 'tvang.decide',
    perm = 'tvang.decide',
    schema = 'TvangDecide',
    writes = true,
    -- A decision to enter somebody's home. A stale Discord snapshot must not be
    -- able to produce one (4.2).
    sensitive = true,
    audit = 'tvang.decided',
    subjectType = TVANG,
    auditDetail = function(input)
        return { kind = input.kind, targetKind = input.targetKind, targetId = input.targetId }
    end,
    handler = function(session, input)
        local err, fields = service.validate(input)
        if err then return route.refuse(err, fields) end

        if not accessRules.canClassify(access.reader(session), input.classification) then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { classification = 'over_clearance' })
        end

        local capacity = capacityOf(session)

        if not service.mayDecide(capacity, input.kind) then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { kind = 'wrong_capacity' })
        end

        input.deciderKind = capacity

        local seconds = input.validSeconds or service.DEFAULT_VALIDITY

        local row = repo.create(input, session, seconds)
        if not row then return route.refuse(FredPD.ErrorCode.INTERNAL) end

        return { id = row.id, number = row.number, tvangsmedel = row }
    end,
})

route.define({
    name = 'tvang.verkstall',
    perm = 'tvang.verkstall',
    schema = 'TvangVerkstall',
    writes = true,
    audit = 'tvang.verkstalld',
    subjectType = TVANG,
    handler = function(session, input)
        local row, refusal = readableTvang(session, input.id)
        if not row then return refusal end

        -- Executing a measure that is not live is the one thing this route
        -- exists to stop being recorded as though it were lawful.
        local live, why = service.isValid(row, os.time())
        if not live then return route.refuse(FredPD.ErrorCode.CONFLICT, { status = why }) end

        if repo.verkstall(row.id, session.agencyId, session.discordId, input.note) == 0 then
            -- Already recorded. Not an error: the officer pressed it twice, and
            -- the first execution stays the recorded one.
            return { id = row.id, alreadyRecorded = true }
        end

        return { id = row.id }
    end,
})

route.define({
    name = 'tvang.upphav',
    perm = 'tvang.decide',
    schema = 'TvangUpphav',
    writes = true,
    sensitive = true,
    audit = 'tvang.upphavd',
    subjectType = TVANG,
    handler = function(session, input)
        local row, refusal = readableTvang(session, input.id)
        if not row then return refusal end

        if repo.upphav(row.id, session.agencyId, session.discordId, input.version) == 0 then
            return route.refuse(FredPD.ErrorCode.CONFLICT)
        end

        return { id = row.id }
    end,
})

-- -----------------------------------------------------------------------------
-- Efterlysning
-- -----------------------------------------------------------------------------

route.define({
    name = 'efterlysning.list',
    perm = 'tvang.view',
    schema = 'EfterlysningList',
    handler = function(session, input)
        local now = os.time()

        local rows = repo.efterlysningList(session.agencyId, {
            grund = input.grund,
            includeCancelled = input.includeCancelled,
        }, input.limit or 50)

        for index = 1, #rows do
            rows[index].live = service.isLive(rows[index], now)
            rows[index].detainOnSight = service.detainOnSight(rows[index].grund)
        end

        return { efterlysningar = access.filterSearch(session, EFTERLYSNING, rows) }
    end,
})

route.define({
    name = 'efterlysning.create',
    perm = 'efterlysning.issue',
    schema = 'EfterlysningCreate',
    writes = true,
    sensitive = true,
    audit = 'efterlysning.issued',
    subjectType = EFTERLYSNING,
    auditDetail = function(input)
        return { personId = input.personId, grund = input.grund }
    end,
    handler = function(session, input)
        if not service.isGrund(input.grund) then
            return route.refuse(FredPD.ErrorCode.INVALID, { grund = 'unknown' })
        end

        if not accessRules.canClassify(access.reader(session), input.classification) then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { classification = 'over_clearance' })
        end

        local row = repo.efterlys(input, session)
        if not row then return route.refuse(FredPD.ErrorCode.INTERNAL) end

        return { id = row.id, number = row.number, efterlysning = row }
    end,
})

route.define({
    name = 'efterlysning.cancel',
    perm = 'efterlysning.issue',
    schema = 'EfterlysningCancel',
    writes = true,
    audit = 'efterlysning.cancelled',
    subjectType = EFTERLYSNING,
    handler = function(session, input)
        local row, refusal = readableEfterlysning(session, input.id)
        if not row then return refusal end

        if repo.cancel(row.id, session.agencyId, session.discordId,
                       input.grund, input.version) == 0 then
            return route.refuse(FredPD.ErrorCode.CONFLICT)
        end

        return { id = row.id }
    end,
})

-- -----------------------------------------------------------------------------
-- Spec 14 exports
-- -----------------------------------------------------------------------------

--- `HasSearchWarrant(targetType, targetId)` -- spec 14.
---
--- Called by raid and door scripts, most importantly `ox_doorlock`, to decide
--- whether to open a door. Three properties this has to hold, and each is a
--- decision rather than an accident:
---
---   * **It answers a plain boolean.** The caller is a door, not a screen.
---   * **It is never wrong permissively.** Anything it cannot resolve is
---     `false`: a bad target kind, a missing id, a measure that has lapsed or
---     been revoked. A door that opens on a malformed call is worse than one
---     that stays shut on a valid one, because only the second gets reported.
---   * **It asks the narrow question.** A kroppsvisitation is a live coercive
---     measure against the same person and does **not** open their front door
---     (`Tvang.authorisesEntry`). Asking "is there any measure" would.
---
--- No session, no agency: a door script has neither, and a husrannsakan decided
--- by one department is not void because a second department exists.
local function hasSearchWarrant(targetType, targetId)
    if not service.isTarget(targetType) then return false end

    local id = tonumber(targetId)
    if not id or id < 1 then return false end

    local now = os.time()
    local rows = repo.forTargetAnyAgency(targetType, id)

    for index = 1, #rows do
        local row = rows[index]

        if service.authorisesEntry(row) and service.isValid(row, now) then
            return true
        end
    end

    return false
end

exports('HasSearchWarrant', hasSearchWarrant)

--- `IsWanted(citizenid)` -- spec 14.
---
--- True when a live efterlysning on this person means "detain on sight".
--- Deliberately narrower than "any efterlysning": somebody wanted to be served
--- a document, or reported missing, is not somebody another script should treat
--- as wanted, and a resource acting on this boolean cannot make the
--- distinction itself.
---
--- The citizenid is resolved to a master record first, because an efterlysning
--- names a person in the index rather than a character identifier.
local function isWanted(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return false end

    -- Every matching person, not the first.
    --
    -- `uq_fpd_persons_identifier` is `(agency_id, identifier)`, so one
    -- citizenid has one master row *per agency*. A `LIMIT 1` with no ORDER BY
    -- picked whichever the optimiser reached first, so on a two-force server
    -- this answered `false` for somebody genuinely wanted whenever the other
    -- agency's row came back. The restrictive direction, but arbitrary rather
    -- than deliberate -- and it threw away the cross-agency reach that is the
    -- whole point of the export.
    local persons = FredPD.Core.db.query(
        'SELECT id FROM fpd_persons WHERE identifier = ?', { citizenid })

    if #persons == 0 then return false end

    local now = os.time()

    for personIndex = 1, #persons do
        local rows = repo.forPerson(persons[personIndex].id)

        for index = 1, #rows do
            if service.detainOnSight(rows[index].grund)
                and service.isLive(rows[index], now) then
                return true
            end
        end
    end

    return false
end

exports('IsWanted', isWanted)
