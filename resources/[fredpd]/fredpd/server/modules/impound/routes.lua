--- Vehicle impound routes (spec 7.15).
---
--- Fires the server-local `fredpd:vehicleImpounded` event on creation --
--- `spaning/events.lua` has held a handler for it since 0012, waiting for the
--- module that would finally raise it. `AddEventHandler`/`TriggerEvent` only
--- (invariant 5): the lookout auto-resolve reads across every agency, which a
--- `TriggerClientEvent` broadcast could never do safely.

local route = FredPD.Core.route
local repo = FredPD.Repo.impound
local service = FredPD.Modules.impound
local access = FredPD.Repo.access

--- `vehicle` is already allowlisted in `access/repo.lua` -- an impound record
--- is about a specific vehicle, the same as a stolen-vehicle flag or a query
--- hit.
local VEHICLE <const> = 'vehicle'

local function readable(session, id)
    local row = repo.byId(id, session.agencyId)
    if not row then return nil, route.refuse(FredPD.ErrorCode.NOT_FOUND) end

    local allowed = access.read(session, VEHICLE, row)
    if not allowed then return nil, route.refuse(FredPD.ErrorCode.RESTRICTED) end

    return allowed
end

-- -----------------------------------------------------------------------------
-- Reads
-- -----------------------------------------------------------------------------

route.define({
    name = 'impound.list',
    perm = 'impound.view',
    schema = 'ImpoundList',
    handler = function(session, input)
        local found = repo.list(session.agencyId, { held = input.held }, input.limit or 50)

        return { impounds = access.filterSearch(session, VEHICLE, found) }
    end,
})

route.define({
    name = 'impound.get',
    perm = 'impound.view',
    schema = 'ImpoundGet',
    handler = function(session, input)
        local row, refusal = readable(session, input.id)
        if not row then return refusal end

        -- Computed fresh on every read, never stored, so the screen always
        -- shows a current running total rather than the balance at whatever
        -- moment it was last written.
        row.feeOwed = service.feeOwed(row, os.time())

        return { impound = row }
    end,
})

-- -----------------------------------------------------------------------------
-- Create
-- -----------------------------------------------------------------------------

route.define({
    name = 'impound.create',
    perm = 'impound.create',
    schema = 'ImpoundCreate',
    writes = true,
    sensitive = true,
    audit = 'impound.created',
    subjectType = VEHICLE,
    auditDetail = function(input)
        return { plate = input.plate, heldReasonKey = input.heldReasonKey }
    end,
    handler = function(session, input)
        local err, fields = service.validateCreate(input)
        if err then return route.refuse(err, fields) end

        local row = repo.create(input, session)
        if not row then return route.refuse(FredPD.ErrorCode.INTERNAL) end

        -- Only when the plate actually resolved to a registry vehicle: the
        -- spaning handler does `tonumber(event.vehicleId)` and bails on nil,
        -- so firing with no vehicle would be harmless, but there is nothing
        -- for it to resolve either, so we do not bother.
        if row.vehicleId then
            TriggerEvent('fredpd:vehicleImpounded', {
                vehicleId = row.vehicleId,
                discordId = session.discordId,
                agencyId = session.agencyId,
            })
        end

        return { id = row.id, number = row.number, impound = row }
    end,
})

-- -----------------------------------------------------------------------------
-- Authorize (investigative / evidence hold)
-- -----------------------------------------------------------------------------

route.define({
    name = 'impound.authorize',
    perm = 'impound.authorize',
    schema = 'ImpoundAuthorize',
    writes = true,
    sensitive = true,
    audit = 'impound.authorized',
    subjectType = VEHICLE,
    auditDetail = function(input) return { id = input.id } end,
    handler = function(session, input)
        local err, fields = service.validateAuthorize(input)
        if err then return route.refuse(err, fields) end

        local row, refusal = readable(session, input.id)
        if not row then return refusal end

        if not service.needsAuthorization(row.heldReasonKey) then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { _input = 'not_needed' })
        end

        if row.holdAuthorizedAt then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { _input = 'already_authorized' })
        end

        if repo.authorize(row.id, session.agencyId, session.discordId) == 0 then
            return route.refuse(FredPD.ErrorCode.CONFLICT)
        end

        return { id = row.id }
    end,
})

-- -----------------------------------------------------------------------------
-- Release
-- -----------------------------------------------------------------------------

route.define({
    name = 'impound.release',
    perm = 'impound.release',
    schema = 'ImpoundRelease',
    writes = true,
    sensitive = true,
    audit = 'impound.released',
    subjectType = VEHICLE,
    auditDetail = function(input) return { id = input.id, feePaid = input.feePaid } end,
    handler = function(session, input)
        local err, fields = service.validateRelease(input)
        if err then return route.refuse(err, fields) end

        local row, refusal = readable(session, input.id)
        if not row then return refusal end

        if row.releasedAt then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { _input = 'already_released' })
        end

        local ok, reasonCode = service.mayRelease(row, input.feePaid)
        if not ok then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { _input = reasonCode })
        end

        if repo.release(row.id, session.agencyId, session.discordId, input.feePaid, input.version) == 0 then
            return route.refuse(FredPD.ErrorCode.CONFLICT)
        end

        return { id = row.id }
    end,
})
