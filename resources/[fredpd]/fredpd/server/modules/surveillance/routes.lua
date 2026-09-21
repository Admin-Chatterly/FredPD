--- Surveillance routes, and the spec 14 export (spec 9).
---
--- Two capacities decide here, the same split `frihet/routes.lua` uses and for
--- the same reason: `capacityOf` derives which one a session holds from its
--- permissions, never from a client-sent field, because a client that could
--- name its own capacity could grant its own wiretap.
---
---   * `surv.request` -- the åklagare applies (`hak.request`).
---   * `surv.decide`  -- the domare grants or refuses (`hak.grant`, `hak.refuse`).
---   * `surv.upphav`  -- either may revoke early (RB 27:23).
---
--- Observing once a measure is granted needs a *third*, narrower kind of
--- permission: which method this session may actually listen to. Spec 9 names
--- them per method (`surv.phone.intercept`, `surv.device.listen`,
--- `surv.tracker.view`, …) because a domare who granted an HRA has not thereby
--- authorised themselves to plant the device -- that is a different officer's
--- job, on a different permission. `hak.session.start`, `hak.session.end` and
--- `hak.intercept.add` all sit behind the broad `surv.view` and then check the
--- row's own `method` against `METHOD_PERM` before doing anything.
---
--- Reads of a live interception are audited even when allowed (invariant 11):
--- `surveillance` has been an allowlisted access record type since M1 for
--- exactly this, so every `access.read` and `access.filterSearch` call below
--- writes the entry -- no separate log table is needed (0015's header).

local route = FredPD.Core.route
local repo = FredPD.Repo.surveillance
local service = FredPD.Modules.surveillance
local access = FredPD.Repo.access
local accessRules = FredPD.Modules.access

--- The access record type. Allowlisted in `access/repo.lua` since M1.
local SURVEILLANCE <const> = 'surveillance'

--- Which granular permission a method's observer must hold.
---
--- `kameraovervakning` shares `surv.device.listen` with `hra`: both are a
--- placed item an officer watches or listens to, and spec 9 gives no separate
--- camera permission.
local METHOD_PERM <const> = {
    hak = 'surv.phone.intercept',
    hra = 'surv.device.listen',
    sparsandare = 'surv.tracker.view',
    kameraovervakning = 'surv.device.listen',
}

--- Which legal capacity this session acts in.
---
--- Mirrors `frihet/routes.lua`'s `capacityOf`. A session holding both grants
--- is treated as the domare, the narrower role -- the same reasoning `frihet`
--- gives: somebody given both has not thereby been made able to grant their
--- own application.
local function capacityOf(session)
    local perms = session.permissions

    if FredPD.Core.perms.satisfies(perms, 'surv.decide') then return 'domare' end
    if FredPD.Core.perms.satisfies(perms, 'surv.request') then return 'aklagare' end

    return nil
end

--- Reads a measure the session is allowed to see, or refuses.
---
--- The same discipline `tvangsmedel/routes.lua`'s `readableTvang` argues for:
--- every write route reads through the access check first, so an officer
--- holding the write grant but not the clearance learns nothing about a
--- measure above it from the shape of the refusal.
local function readable(session, id)
    local row = repo.byId(id, session.agencyId)
    if not row then return nil, route.refuse(FredPD.ErrorCode.NOT_FOUND) end

    local allowed = access.read(session, SURVEILLANCE, row)
    if not allowed then return nil, route.refuse(FredPD.ErrorCode.RESTRICTED) end

    return allowed
end

--- Adds the derived fields a screen needs.
---
--- `notLiveBecause` is `hak.get`'s alone, the same asymmetry
--- `tvangsmedel/routes.lua` gives `tvang.list` and `tvang.get`: it costs a
--- second return the list does not need for fifty rows, and `status` already
--- carries `begard`/`avslagen`/`upphavd` on its own -- what it cannot say is
--- *when inside `beviljad`* a window has not opened yet or has closed.
local function decorate(row, now, withReason)
    local live, why = service.isValid(row, now)

    row.live = live
    row.banner = service.bannerFor(row, now)
    row.needsRenewal = service.needsRenewal(row, now)
    if withReason then row.notLiveBecause = why end

    return row
end

-- -----------------------------------------------------------------------------
-- Reads
-- -----------------------------------------------------------------------------

route.define({
    name = 'hak.list',
    perm = 'surv.view',
    schema = 'HakList',
    handler = function(session, input)
        local now = os.time()

        local found = repo.list(session.agencyId, {
            fuId = input.fuId,
            status = input.status,
            liveOnly = input.liveOnly,
        }, input.limit or 50)

        -- Before the filter (spec 4.5, `spaning/routes.lua`'s header argues
        -- this at length): a stub carries three fields and no more, and a
        -- decorator that reaches one is how the next field somebody adds here
        -- becomes a leak.
        for index = 1, #found do decorate(found[index], now) end

        local rows = access.filterSearch(session, SURVEILLANCE, found)

        return { hak = rows }
    end,
})

route.define({
    name = 'hak.get',
    perm = 'surv.view',
    schema = 'HakGet',
    sensitive = true,
    handler = function(session, input)
        local row, refusal = readable(session, input.id)
        if not row then return refusal end

        return { hak = decorate(row, os.time(), true) }
    end,
})

route.define({
    name = 'hak.log',
    perm = 'surv.log.view',
    schema = 'HakLog',
    sensitive = true,
    audit = 'hak.log.viewed',
    subjectType = SURVEILLANCE,
    handler = function(session, input)
        local hak = repo.byId(input.hakId, session.agencyId)
        if not hak then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

        local allowed = access.read(session, SURVEILLANCE, hak)
        if not allowed then return route.refuse(FredPD.ErrorCode.RESTRICTED) end

        return {
            id = allowed.id,
            sessions = repo.sessionsFor(allowed.id),
            intercepts = repo.interceptsFor(allowed.id),
        }
    end,
})

-- -----------------------------------------------------------------------------
-- Request, grant, refuse, upphäva
-- -----------------------------------------------------------------------------

route.define({
    name = 'hak.request',
    perm = 'surv.request',
    schema = 'HakRequest',
    writes = true,
    sensitive = true,
    audit = 'hak.requested',
    subjectType = SURVEILLANCE,
    auditDetail = function(input)
        return { targetKind = input.targetKind, method = input.method, fuId = input.fuId }
    end,
    handler = function(session, input)
        if capacityOf(session) ~= 'aklagare' then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { _input = 'wrong_capacity' })
        end

        local err, fields = service.validateRequest(input)
        if err then return route.refuse(err, fields) end

        if not accessRules.canClassify(access.reader(session), input.classification) then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { classification = 'over_clearance' })
        end

        local row = repo.request(input, session)
        if not row then return route.refuse(FredPD.ErrorCode.INTERNAL) end

        return { id = row.id, number = row.number, hak = decorate(row, os.time()) }
    end,
})

route.define({
    name = 'hak.grant',
    perm = 'surv.decide',
    schema = 'HakGrant',
    writes = true,
    sensitive = true,
    audit = 'hak.granted',
    subjectType = SURVEILLANCE,
    handler = function(session, input)
        if capacityOf(session) ~= 'domare' then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { _input = 'wrong_capacity' })
        end

        local row, refusal = readable(session, input.id)
        if not row then return refusal end

        local seconds = input.validSeconds or service.DEFAULT_VALIDITY

        if repo.grant(row.id, session.agencyId, session.discordId,
                      input.courtRef, seconds, input.version) == 0 then
            return route.refuse(FredPD.ErrorCode.CONFLICT)
        end

        return { id = row.id }
    end,
})

route.define({
    name = 'hak.refuse',
    perm = 'surv.decide',
    schema = 'HakRefuse',
    writes = true,
    sensitive = true,
    audit = 'hak.refused',
    subjectType = SURVEILLANCE,
    handler = function(session, input)
        if capacityOf(session) ~= 'domare' then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { _input = 'wrong_capacity' })
        end

        if not service.isGrund(input.grund) then
            return route.refuse(FredPD.ErrorCode.INVALID, { grund = 'not_a_key' })
        end

        local row, refusal = readable(session, input.id)
        if not row then return refusal end

        if repo.refuse(row.id, session.agencyId, session.discordId,
                       input.grund, input.version) == 0 then
            return route.refuse(FredPD.ErrorCode.CONFLICT)
        end

        return { id = row.id }
    end,
})

route.define({
    name = 'hak.upphav',
    perm = 'surv.upphav',
    schema = 'HakUpphav',
    writes = true,
    sensitive = true,
    audit = 'hak.upphavd',
    subjectType = SURVEILLANCE,
    handler = function(session, input)
        local capacity = capacityOf(session)
        if not service.mayUpphav(capacity) then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { _input = 'wrong_capacity' })
        end

        if input.grund ~= nil and not service.isUpphavandegrund(input.grund) then
            return route.refuse(FredPD.ErrorCode.INVALID, { grund = 'not_a_key' })
        end

        local row, refusal = readable(session, input.id)
        if not row then return refusal end

        if repo.upphav(row.id, session.agencyId, session.discordId,
                       input.grund, input.version) == 0 then
            return route.refuse(FredPD.ErrorCode.CONFLICT)
        end

        return { id = row.id }
    end,
})

-- -----------------------------------------------------------------------------
-- Observing
-- -----------------------------------------------------------------------------

route.define({
    name = 'hak.session.start',
    perm = 'surv.view',
    schema = 'HakSessionStart',
    writes = true,
    sensitive = true,
    audit = 'hak.session.started',
    subjectType = SURVEILLANCE,
    handler = function(session, input)
        local row, refusal = readable(session, input.hakId)
        if not row then return refusal end

        if not service.isValid(row, os.time()) then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { status = 'not_live' })
        end

        local required = METHOD_PERM[row.method]
        if not required or not FredPD.Core.perms.satisfies(session.permissions, required) then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { method = 'wrong_capability' })
        end

        local sessionId = repo.startSession(row.id, session.discordId)

        return { id = sessionId }
    end,
})

route.define({
    name = 'hak.session.end',
    perm = 'surv.view',
    schema = 'HakSessionEnd',
    writes = true,
    audit = 'hak.session.ended',
    subjectType = SURVEILLANCE,
    handler = function(session, input)
        if repo.endSession(input.id, session.discordId, input.minimizationNote) == 0 then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        return { id = input.id }
    end,
})

route.define({
    name = 'hak.intercept.add',
    perm = 'surv.view',
    schema = 'HakInterceptAdd',
    writes = true,
    sensitive = true,
    audit = 'hak.intercept.added',
    subjectType = SURVEILLANCE,
    handler = function(session, input)
        if not service.isInterceptKind(input.kind) then
            return route.refuse(FredPD.ErrorCode.INVALID, { kind = 'not_a_key' })
        end

        local row, refusal = readable(session, input.hakId)
        if not row then return refusal end

        if not service.isValid(row, os.time()) then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { status = 'not_live' })
        end

        local required = METHOD_PERM[row.method]
        if not required or not FredPD.Core.perms.satisfies(session.permissions, required) then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { method = 'wrong_capability' })
        end

        local id = repo.addIntercept(input, session.discordId)

        return { id = id }
    end,
})

-- -----------------------------------------------------------------------------
-- Spec 14 export
-- -----------------------------------------------------------------------------

--- `HasActiveWarrant(targetType, targetRef, warrantKind, method?)` -- spec 14.
---
--- Flat parameters, the same shape `HasSearchWarrant(targetType, targetId)`
--- already uses, rather than a caller-constructed table whose field names
--- would be this file's alone to know. `warrantKind` is always `'surveillance'`
--- today; the parameter exists because spec 14 documents this export as
--- generic across warrant kinds and a caller naming it explicitly is one that
--- will not break when a second kind is added. `method` narrows to one of the
--- four (`hak`, `hra`, `sparsandare`, `kameraovervakning`); omitted, any live
--- measure on the target answers true.
---
--- `targetRef` is a record id for `person` and `vehicle`, and the phone
--- number or address itself for `phone` and `location` -- neither of which is
--- a foreign key into anything this suite holds (0015). Which one it is
--- follows from `targetType`, the same way `Repo.request`'s caller decides
--- between `target_id` and `target_label`.
---
--- No session, no agency, the same reach `HasSearchWarrant` has and for the
--- same reason: a measure decided by one department is not void because a
--- second department exists on the server.
local function hasActiveWarrant(targetType, targetRef, warrantKind, method)
    if warrantKind ~= 'surveillance' then return false end
    if not service.isTarget(targetType) then return false end
    if method and not service.isMethod(method) then return false end

    local rows
    if targetType == 'phone' or targetType == 'location' then
        if type(targetRef) ~= 'string' or targetRef == '' then return false end
        rows = repo.forTargetLabelAnyAgency(targetType, targetRef)
    else
        local id = tonumber(targetRef)
        if not id or id < 1 then return false end
        rows = repo.forTargetAnyAgency(targetType, id)
    end

    return service.firstValid(rows, os.time(), method) ~= nil
end

exports('HasActiveWarrant', hasActiveWarrant)
