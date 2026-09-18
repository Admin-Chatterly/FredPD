--- Frihetsberövande routes (spec 7.9).
---
--- The permission set here is the three decision-makers of RB, and it is the
--- one place in FredPD where a permission stands for a *legal capacity* rather
--- than for a job in the department:
---
---   * `frihet.gripande` -- seize somebody (RB 24:7). Patrol work.
---   * `frihet.anhallande` -- the åklagare's decision (RB 24:6).
---   * `frihet.haktning` -- the tingsrätt's decision (RB 24:13).
---   * `frihet.frigiv` -- release, held by everyone who can do any of the above
---     and by the officer holding the person. A frihetsberövande that should end
---     must be able to end at once.
---
--- `capacityOf` turns the permission set into the capacity the service checks.
--- The order matters: somebody holding both prosecutor and court grants is
--- treated as the court, because that is the narrower role and a server that
--- has given one person both has not thereby made them able to anhålla in their
--- own häktningsförhandling.

local route = FredPD.Core.route
local repo = FredPD.Repo.frihet
local service = FredPD.Modules.frihet
local brott = FredPD.Modules.brott
local access = FredPD.Repo.access
local accessRules = FredPD.Modules.access

--- The access record type a frihetsberövande is filed under.
---
--- `arrest` rather than a new type, because the access module's allowlist
--- already carries it and a grant written against `arrest` is what a supervisor
--- means either way.
local FRIHET <const> = 'arrest'

--- The timezone offset RB 24:12's local noon is computed in.
---
--- **The server's own zone**, which is what `nil` means to
--- `Frihet.localNoonAfter`. `fredpd:timezone` holds an IANA name
--- (`Europe/Stockholm`) and is used by `Intl` in the NUI for *formatting*; Lua
--- has no way to resolve a name to an offset without a tz database, so the
--- server's own clock is the only zone available here.
---
--- That makes the host's timezone load-bearing for this one rule, and it is
--- worth saying out loud: a server whose host runs in UTC while the department
--- it simulates is in Sweden will compute the RB 24:12 deadline at 12:00 UTC
--- rather than 12:00 CET, an hour or two out. Section 16 already expects the
--- host to be configured for the deployment; this is the thing that depends on
--- it. The parameter exists on the service so busted can pin the arithmetic at
--- a known offset regardless of where CI runs.
local function timezoneOffset()
    return nil
end

--- Which legal capacity this session acts in.
---
--- Derived from the permission set, never sent: a client that could name its
--- own capacity could anhålla itself.
local function capacityOf(session)
    local perms = session.permissions

    if FredPD.Core.perms.satisfies(perms, 'frihet.haktning') then return 'domare' end
    if FredPD.Core.perms.satisfies(perms, 'frihet.anhallande') then return 'aklagare' end

    return 'polis'
end

--- Reads a chain the session is allowed to see, or refuses.
local function readable(session, id)
    local row = repo.byId(id, session.agencyId)
    if not row then return nil, route.refuse(FredPD.ErrorCode.NOT_FOUND) end

    local allowed = access.read(session, FRIHET, row)
    if not allowed then return nil, route.refuse(FredPD.ErrorCode.RESTRICTED) end

    return allowed
end

--- Adds the computed clocks to a row on its way out.
---
--- Computed on the server rather than in the NUI, and not because the browser
--- could not subtract: RB 24:12 is a local noon three days out, which is the
--- rule easiest to implement almost correctly, and a second implementation in
--- the client would be the one nobody tested. The NUI renders the number it is
--- given and counts down from it.
local function withClocks(row, now, offset)
    local key, deadline = service.nextDeadline(row, now, offset)

    row.deadlines = service.deadlines(row, now, offset)
    row.nextDeadline = key
    row.nextDeadlineAt = deadline and deadline.at or nil
    row.heldFor = service.heldFor(row, now)
    row.needsAttention = service.needsAttention(row, now, offset)

    return row
end

-- -----------------------------------------------------------------------------
-- Reads
-- -----------------------------------------------------------------------------

route.define({
    name = 'frihet.open',
    perm = 'frihet.view',
    schema = 'FrihetOpen',
    handler = function(session, input)
        local now = os.time()
        local offset = timezoneOffset()

        local rows = access.filterSearch(
            session, FRIHET, repo.open(session.agencyId, input.limit or 50))

        for index = 1, #rows do withClocks(rows[index], now, offset) end

        return { frihetsberovanden = rows }
    end,
})

route.define({
    name = 'frihet.list',
    perm = 'frihet.view',
    schema = 'FrihetList',
    handler = function(session, input)
        local now = os.time()
        local offset = timezoneOffset()

        local rows = access.filterSearch(session, FRIHET, repo.list(session.agencyId, {
            status = input.status,
            personId = input.personId,
            fuId = input.fuId,
        }, input.limit or 50))

        for index = 1, #rows do withClocks(rows[index], now, offset) end

        return { frihetsberovanden = rows }
    end,
})

route.define({
    name = 'frihet.get',
    perm = 'frihet.view',
    schema = 'FrihetGet',
    handler = function(session, input)
        local row, refusal = readable(session, input.id)
        if not row then return refusal end

        local charges = repo.charges(row.id)

        local skalor = {}
        for index = 1, #charges do
            skalor[index] = brott.straffskala(charges[index])
            charges[index].citation = brott.citation(charges[index])
        end

        return {
            frihetsberovande = withClocks(row, os.time(), timezoneOffset()),
            brott = charges,
            straffskala = #skalor > 0 and brott.gemensamStraffskala(skalor) or nil,
            log = repo.log(row.id),
        }
    end,
})

-- -----------------------------------------------------------------------------
-- The chain
-- -----------------------------------------------------------------------------

route.define({
    name = 'frihet.gripande',
    perm = 'frihet.gripande',
    schema = 'FrihetGripande',
    writes = true,
    audit = 'frihet.gripande',
    subjectType = FRIHET,
    auditDetail = function(input) return { personId = input.personId, grund = input.grund } end,
    handler = function(session, input)
        if not accessRules.canClassify(access.reader(session), input.classification) then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { classification = 'over_clearance' })
        end

        local row = repo.gripande(input, session)
        if not row then return route.refuse(FredPD.ErrorCode.INTERNAL) end

        return {
            id = row.id,
            number = row.number,
            frihetsberovande = withClocks(row, os.time(), timezoneOffset()),
        }
    end,
})

--- The body every decision in the chain shares.
---
--- Declared out longhand below rather than built by a factory, because
--- `tools/wiring-check.ts` reads route names as string literals and a route it
--- cannot see is a route whose permission can quietly be granted to nobody.
local function runDecision(session, input, action)
    local row, refusal = readable(session, input.id)
    if not row then return refusal end

    local ok, why = service.canDecide(row, action, capacityOf(session))
    if not ok then
        return route.refuse(
            (why == 'already_released' or why == 'not_allowed')
                and FredPD.ErrorCode.CONFLICT
                or FredPD.ErrorCode.FORBIDDEN,
            { status = why })
    end

    local toStatus = service.nextStatus(row.status, action)

    -- An anhållande and a release both rest on a ground, and both are quoted
    -- afterwards. The ground is a locale key, never a sentence (invariant 6).
    if (toStatus == 'anhallen' or toStatus == 'frigiven') and not input.grund then
        return route.refuse(FredPD.ErrorCode.INVALID, { grund = 'required' })
    end

    if repo.decide(row.id, session.agencyId, toStatus, session.discordId,
                   input.grund, input.version) == 0 then
        return route.refuse(FredPD.ErrorCode.CONFLICT)
    end

    return { id = row.id, status = toStatus }
end

route.define({
    name = 'frihet.anhallande',
    perm = 'frihet.anhallande',
    schema = 'FrihetDecision',
    writes = true,
    -- A decision that keeps somebody locked up. A stale Discord snapshot must
    -- not be able to produce one (4.2).
    sensitive = true,
    audit = 'frihet.anhallande',
    subjectType = FRIHET,
    handler = function(session, input)
        return runDecision(session, input, 'anhall')
    end,
})

route.define({
    name = 'frihet.framstallan',
    perm = 'frihet.anhallande',
    schema = 'FrihetDecision',
    writes = true,
    sensitive = true,
    audit = 'frihet.framstallan',
    subjectType = FRIHET,
    handler = function(session, input)
        return runDecision(session, input, 'framstall')
    end,
})

route.define({
    name = 'frihet.haktning',
    perm = 'frihet.haktning',
    schema = 'FrihetDecision',
    writes = true,
    sensitive = true,
    audit = 'frihet.haktning',
    subjectType = FRIHET,
    handler = function(session, input)
        return runDecision(session, input, 'hakta')
    end,
})

route.define({
    name = 'frihet.frigiv',
    perm = 'frihet.frigiv',
    schema = 'FrihetDecision',
    writes = true,
    -- Deliberately **not** `sensitive`. Every other decision here is, because
    -- each keeps somebody locked up and a stale permission snapshot must not be
    -- able to produce one. This is the one that lets somebody go, and refusing
    -- it during a Discord outage would hold a person because a third party's
    -- API was down.
    audit = 'frihet.frigiven',
    subjectType = FRIHET,
    handler = function(session, input)
        return runDecision(session, input, 'frigiv')
    end,
})

route.define({
    name = 'frihet.underratta',
    perm = 'frihet.gripande',
    schema = 'FrihetGet',
    writes = true,
    audit = 'frihet.underrattad',
    subjectType = FRIHET,
    handler = function(session, input)
        local row, refusal = readable(session, input.id)
        if not row then return refusal end

        -- Written once (RB 24:9). A second call is not an error -- the officer
        -- pressed it twice -- but it does not move the timestamp, because the
        -- question asked afterwards is when they were *first* told.
        if repo.underratta(row.id, session.agencyId) == 0 then
            return { id = row.id, alreadyRecorded = true }
        end

        return { id = row.id }
    end,
})

-- -----------------------------------------------------------------------------
-- What somebody is held for, and the log
-- -----------------------------------------------------------------------------

route.define({
    name = 'frihet.charges.set',
    perm = 'frihet.gripande',
    schema = 'FrihetCharges',
    writes = true,
    audit = 'frihet.charges.set',
    subjectType = FRIHET,
    handler = function(session, input)
        local row, refusal = readable(session, input.id)
        if not row then return refusal end

        if not service.isOpen(row) then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { status = 'already_released' })
        end

        local ids, reason = brott.parseIds(input.brottIds, 25)
        if not ids then return route.refuse(FredPD.ErrorCode.INVALID, { brottIds = reason }) end

        local rows = FredPD.Repo.brott.byIds(ids, session.agencyId)
        if not brott.expandCharges(ids, rows) then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND, { brottIds = 'unknown' })
        end

        local charges = {}
        for index = 1, #ids do
            charges[index] = { brottId = ids[index], stage = 'fullbordat' }
        end

        if not repo.replaceCharges(row.id, charges, session.discordId) then
            return route.refuse(FredPD.ErrorCode.INTERNAL)
        end

        return { id = row.id, count = #charges }
    end,
})

route.define({
    name = 'frihet.log.add',
    perm = 'frihet.gripande',
    schema = 'FrihetLog',
    writes = true,
    audit = 'frihet.logged',
    subjectType = FRIHET,
    handler = function(session, input)
        local row, refusal = readable(session, input.id)
        if not row then return refusal end

        repo.addLog(row.id, input.kind, input.note, session.discordId)

        return { id = row.id }
    end,
})
