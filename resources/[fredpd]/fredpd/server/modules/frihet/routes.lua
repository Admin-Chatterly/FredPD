--- Frihetsberövande routes (spec 7.9).
---
--- The permission set here is the three decision-makers of RB, and it is the
--- one place in FredPD where a permission stands for a *legal capacity* rather
--- than for a job in the department:
---
---   * `frihet.gripande` -- arrest somebody (RB 24:7). Patrol work.
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
--- **The host's own zone by default**, which is what `nil` means to
--- `Frihet.localNoonAfter`: the host's C library carries a tz database and
--- follows daylight saving, and Lua cannot resolve `fredpd:timezone`'s IANA
--- name without one. Section 16 expects the host to be configured for the
--- deployment, and this is the rule that depends on it.
---
--- `fredpd:timezone_offset` overrides that for the host that cannot be
--- reconfigured — a server running in UTC while the department it simulates is
--- in Sweden would otherwise compute the deadline at 12:00 UTC rather than
--- 12:00 CET, an hour or two early, on the figure an officer quotes to a
--- prosecutor. `Frihet.offsetFromSetting` reads it, and busted pins both the
--- reading and the arithmetic regardless of where CI runs.
--- Read once, because a convar does not change under a running resource and
--- this is called for every row of every list.
local configuredOffset, offsetRejected =
    service.offsetFromSetting(FredPD.Config.shared.timezoneOffset)

if offsetRejected then
    -- Loud, and not fatal: the deadline falls back to the host's own zone,
    -- which is the documented default. Silence would leave a typo in a convar
    -- quietly deciding when somebody must be released.
    print(('[fredpd] fredpd:timezone_offset is not a readable offset (%s); '
        .. 'RB 24:12 will be computed in the host timezone')
        :format(tostring(FredPD.Config.shared.timezoneOffset)))
end

local function timezoneOffset()
    return configuredOffset
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

--- Is anybody signed on who could take the decision this action needs?
---
--- Counts sessions holding the real capacity's permission (spec 7.9.1), less
--- the caller, superusers and stale snapshots -- `Session.countHolding` says
--- why each is left out. The stand-in rules turn on this answer.
local DECISION_PERMISSION <const> = {
    aklagare = 'frihet.anhallande',
    domare = 'frihet.haktning',
}

local CAPACITY_OF_PERMISSION <const> = {
    ['frihet.anhallande'] = 'aklagare',
    ['frihet.haktning'] = 'domare',
}

local function deciderOnline(session, capacity)
    local permission = DECISION_PERMISSION[capacity]
    if not permission then return false end

    return FredPD.Core.session.countHolding(permission, session.agencyId, session.src) > 0
end

--- The name each decision's route and locale keys use, and the permission
--- its ordinary route asks for.
local DECISION_NAME <const> = {
    anhall = 'anhallande', framstall = 'framstallan', hakta = 'haktning', frigiv = 'frigiv',
}

local ROUTE_PERMISSION <const> = {
    anhall = 'frihet.anhallande', framstall = 'frihet.anhallande',
    hakta = 'frihet.haktning', frigiv = 'frihet.frigiv',
}

local function fallbackEnabled()
    local config = FredPD.Config.server.frihet
    return config ~= nil and config.fallback == true
end

--- The capacity this session may stand in with for `action` on `row`.
local function standInCapacity(session, row, action)
    if not fallbackEnabled() then return nil, 'stand_in_off' end

    local required = service.deciderFor(action)

    return service.fallbackCapacity(row, action, capacityOf(session),
        function(permission)
            return FredPD.Core.perms.satisfies(session.permissions, permission)
        end,
        required ~= nil and deciderOnline(session, required),
        session.discordId)
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

--- Tells whoever takes the next decision in the chain that it is waiting on
--- them (spec 7.9). A custody chain that sits unread is somebody held with
--- nobody deciding, and the åklagare used to find out only by opening the
--- screen. The notice carries the chain's number and nothing else, and only
--- reaches a session that could read the chain anyway.
local NOTICE_FOR <const> = {
    ['frihet.anhallande'] = 'frihet.notify.needsDecision',
    ['frihet.haktning'] = 'frihet.notify.needsHaktning',
}

local function announceNext(session, id)
    local row = repo.byId(id, session.agencyId)
    if not row then return end

    local permission = service.nextDecisionPermission(row.status)
    if not permission then return end

    local function tellable(other)
        return other.agencyId == session.agencyId and other.src ~= session.src
            and access.mayBeToldOf(other, FRIHET, row)
    end

    FredPD.Core.push.notifyPermission(permission, NOTICE_FOR[permission],
        { number = row.number }, { type = 'warning' }, tellable)

    -- Nobody holding the real capacity was told, so nobody is going to decide:
    -- tell whoever may stand in (spec 7.9.1). The superusers the first pass
    -- reached do not count as somebody deciding.
    if fallbackEnabled()
        and FredPD.Core.session.countHolding(permission, session.agencyId, nil) == 0
    then
        local capacity = CAPACITY_OF_PERMISSION[permission]
        local fallback = service.fallbackPermission(capacity)

        FredPD.Core.push.notifyPermission(fallback, 'frihet.notify.needsStandIn.' .. capacity,
            { number = row.number }, { type = 'warning' },
            function(other)
                return tellable(other) and not other.superuser
                    and not other.permissions['*']
                    and not FredPD.Core.perms.satisfies(other.permissions, permission)
            end)
    end
end

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

        -- Which decisions this session may take right now, and whether in
        -- its own capacity or as a stand-in, so the screen offers only the
        -- buttons that would be accepted. The routes check again; this is a
        -- courtesy, not the control (invariant 4).
        local decisions = {}
        local capacity = capacityOf(session)

        for action, name in pairs(DECISION_NAME) do
            if FredPD.Core.perms.satisfies(session.permissions, ROUTE_PERMISSION[action])
                and service.canDecide(row, action, capacity)
                and not service.actedOn(row, action, session.discordId)
            then
                decisions[name] = 'self'
            elseif standInCapacity(session, row, action) then
                decisions[name] = 'standIn'
            end
        end

        return {
            decisions = decisions,
            frihetsberovande = withClocks(row, os.time(), timezoneOffset()),
            brott = charges,
            straffskala = #skalor > 0 and brott.gemensamStraffskala(skalor) or nil,
            log = repo.log(row.id, session.agencyId),
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

        -- The person has to be one this session may read, and the check has
        -- to happen before anything is written.
        --
        -- Without it `personId` was an unvalidated number: `frihet.gripande` is
        -- granted to patrol, so an officer could walk the id space, create a
        -- chain against a person in another agency, and -- through the event
        -- below -- take down every agency's efterlysningar and lookouts for
        -- them. The route also echoed back `person_number` from the JOIN,
        -- which made it an existence oracle for other agencies' records.
        -- `Repo.readPerson` is the persons module's own entry point: it scopes
        -- to the agency, runs the access check and audits a restricted read
        -- (invariant 11). Reusing it rather than writing a second lookup means
        -- there is one definition of "may this session see this person".
        local person, visibility = FredPD.Repo.persons.readPerson(session, input.personId)

        if not person then
            return route.refuse(
                visibility == 'missing' and FredPD.ErrorCode.NOT_FOUND
                    or FredPD.ErrorCode.RESTRICTED,
                { personId = visibility == 'missing' and 'unknown' or 'restricted' })
        end

        local row = repo.gripande(input, session)
        if not row then return route.refuse(FredPD.ErrorCode.INTERNAL) end

        -- 7.13's auto-resolve, announced rather than performed. A gripande is
        -- what an efterlysning existed to produce, so every live one on this
        -- person has to come down -- otherwise the next officer to run them
        -- gets a red "detain on sight" banner for somebody already in a cell,
        -- and the one after that stops believing the banners.
        --
        -- Fired as a **server-local event** (spec 14) instead of reaching into
        -- the tvångsmedel module, because this resource's rule is that a module
        -- talks to another through its service and never its repo. Cancelling
        -- an efterlysning is a write, the service holds no writes, and the way
        -- out is not to bend the rule: the module that owns the efterlysningar
        -- listens for this and decides for itself what a gripande means for
        -- them. It also gives other resources the same hook for free.
        TriggerEvent('fredpd:gripande', {
            frihetId = row.id,
            personId = input.personId,
            agencyId = session.agencyId,
            discordId = session.discordId,
            -- So a record started from this one is never filed lower (4.5).
            classification = input.classification or 'internal',
            personClassification = person.classification,
        })

        announceNext(session, row.id)

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
local function refuseDecision(why)
    return route.refuse(
        (why == 'already_released' or why == 'out_of_order')
            and FredPD.ErrorCode.CONFLICT
            or FredPD.ErrorCode.FORBIDDEN,
        { status = why })
end

local function runDecision(session, input, action, standIn)
    local row, refusal = readable(session, input.id)
    if not row then return refusal end

    local ok, why

    if standIn then
        -- The capacity comes from the stand-in rules, never from the input:
        -- nobody holding the real one is on, this session holds the stand-in
        -- grant, and it took no earlier decision on this chain (7.9.1).
        ok, why = standInCapacity(session, row, action)
    else
        ok, why = service.canDecide(row, action, capacityOf(session))

        -- The reverse of the stand-in rule: a domare who stood in as the
        -- åklagare on this chain does not then sit as the court on it.
        if ok and service.actedOn(row, action, session.discordId) then
            ok, why = false, 'own_chain'
        end
    end

    if not ok then return refuseDecision(why) end

    local toStatus = service.nextStatus(row.status, action)

    -- An anhållande and a release both rest on a ground, and both are quoted
    -- afterwards. The ground is a locale key, never a sentence (invariant 6).
    if (toStatus == 'anhallen' or toStatus == 'frigiven') and not input.grund then
        return route.refuse(FredPD.ErrorCode.INVALID, { grund = 'required' })
    end

    local decided

    if standIn then
        -- On the face of the custody record, not only in the audit trail:
        -- whoever reads the chain afterwards -- the åklagare coming on in the
        -- morning -- sees that this decision was taken by a stand-in, and by
        -- whom. Written in the decision's own transaction.
        decided = repo.decideAsStandIn(row.id, session.agencyId, toStatus, session.discordId,
            input.grund, input.version, 'frihet.logKind.stand_in_' .. action)
    else
        decided = repo.decide(row.id, session.agencyId, toStatus, session.discordId,
            input.grund, input.version)
    end

    if decided == 0 then
        return route.refuse(FredPD.ErrorCode.CONFLICT)
    end

    announceNext(session, row.id)

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

-- -----------------------------------------------------------------------------
-- Standing in (spec 7.9.1)
-- -----------------------------------------------------------------------------
--
-- The same three decisions, taken by a supervisor for the åklagare or by
-- command for the domare, and only while nobody holding the real capacity is
-- signed on. Separate routes rather than a flag on the ordinary ones, so the
-- permission a route needs is still readable from the route, and so the audit
-- trail names a stand-in decision as one without anybody reading its detail.
-- `frihet.fallback = false` in `config/server.lua` turns all three off.

route.define({
    name = 'frihet.fallback.anhallande',
    perm = 'frihet.fallback.aklagare',
    schema = 'FrihetDecision',
    writes = true,
    sensitive = true,
    audit = 'frihet.fallback.anhallande',
    subjectType = FRIHET,
    handler = function(session, input)
        return runDecision(session, input, 'anhall', true)
    end,
})

route.define({
    name = 'frihet.fallback.framstallan',
    perm = 'frihet.fallback.aklagare',
    schema = 'FrihetDecision',
    writes = true,
    sensitive = true,
    audit = 'frihet.fallback.framstallan',
    subjectType = FRIHET,
    handler = function(session, input)
        return runDecision(session, input, 'framstall', true)
    end,
})

route.define({
    name = 'frihet.fallback.haktning',
    perm = 'frihet.fallback.domare',
    schema = 'FrihetDecision',
    writes = true,
    sensitive = true,
    audit = 'frihet.fallback.haktning',
    subjectType = FRIHET,
    handler = function(session, input)
        return runDecision(session, input, 'hakta', true)
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

        -- The kind is a locale key, and the schema can only say "a string".
        -- Checked here because the NUI draws it with `t()`, which prints an
        -- unknown key as itself: without this the field was a way to put an
        -- arbitrary sentence on the face of a custody record (invariant 6).
        if not service.isOfficerLogKind(input.kind) then
            return route.refuse(FredPD.ErrorCode.INVALID, { kind = 'not_a_key' })
        end

        repo.addLog(row.id, input.kind, input.note, session.discordId)

        return { id = row.id }
    end,
})

-- -----------------------------------------------------------------------------
-- Printing (7.28, ADR-020)
-- -----------------------------------------------------------------------------

--- The custody log as its printed copy reads: the chain's facts above, and
--- every entry below, in order, with who made it.
FredPD.Modules.documents.register('custody', function(session, id)
    if not FredPD.Core.perms.satisfies(session.permissions, 'frihet.view') then
        return nil, route.refuse(FredPD.ErrorCode.FORBIDDEN)
    end

    local row, refusal = readable(session, id)
    if not row then return nil, refusal end

    local documents = FredPD.Modules.documents
    local t = FredPD.t

    local fields = {
        { label = t('document.field.number'), value = row.number },
        { label = t('document.field.status'), value = t('frihet.status.' .. tostring(row.status)) },
        { label = t('document.field.arrested'), value = documents.moment(row.gripenAt) },
        { label = t('document.field.ground'), value = row.gripandeGrund and t('frihet.grund.' .. row.gripandeGrund) or '' },
        { label = t('document.field.place'), value = row.gripandePlats or '' },
    }

    local person = row.personId and FredPD.Repo.persons.readPerson(session, row.personId) or nil
    if person then table.insert(fields, 2, { label = t('document.field.person'), value = documents.personLine(person) }) end

    local entries = {}
    for _, entry in ipairs(repo.log(row.id, session.agencyId)) do
        entries[#entries + 1] = {
            type = 'listItem',
            content = { {
                type = 'paragraph',
                content = { { type = 'text', text = t('document.custody.entry', {
                    at = documents.moment(entry.loggedAt),
                    kind = t('frihet.logKind.' .. tostring(entry.kind)),
                    by = entry.loggedByCallsign or '',
                    note = entry.note or '',
                }) } },
            } },
        }
    end

    return {
        title = t('document.title.custody', { number = row.number }),
        classification = row.classification,
        fields = fields,
        body = {
            type = 'doc',
            content = {
                { type = 'heading', attrs = { level = 2 }, content = { { type = 'text', text = t('document.custody.log') } } },
                { type = 'orderedList', content = entries },
            },
        },
    }
end)

