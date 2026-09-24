--- Vehicle impound routes (spec 7.15).
---
--- Fires the server-local `fredpd:vehicleImpounded` event on creation --
--- `spaning/events.lua` has held a handler for it since 0012, waiting for the
--- module that would finally raise it. `AddEventHandler`/`TriggerEvent` only
--- (invariant 5): the lookout auto-resolve reads across every agency, which a
--- `TriggerClientEvent` broadcast could never do safely.

-- luacheck: read globals GetPedInVehicleSeat IsPedAPlayer DeleteEntity GetEntityRoutingBucket
-- luacheck: read globals GetPlayerRoutingBucket GetVehicleClass GetHashKey GetAllVehicles

local route = FredPD.Core.route
local repo = FredPD.Repo.impound
local service = FredPD.Modules.impound
local access = FredPD.Repo.access

--- `vehicle` is already allowlisted in `access/repo.lua` -- an impound record
--- is about a specific vehicle, the same as a stolen-vehicle flag or a query
--- hit.
local VEHICLE <const> = 'vehicle'

--- The street half of an impound (ADR-016): config for the tow, and the
--- garage write, which only a tow that actually removed the car ever makes.
local function world()
    return FredPD.Config.server.impound and FredPD.Config.server.impound.world or {}
end

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
-- Tow: impound the car in front of you (ox_target)
-- -----------------------------------------------------------------------------

--- Is a car with this plate anywhere in the world? A garage row is never
--- marked held, or handed back, while a car carrying its plate is still
--- driving about -- that car is the real one, or a clone of it, and either
--- way a second copy must not come out of the garage.
local function plateInWorld(plate)
    local wanted = tostring(plate):upper():match('^%s*(.-)%s*$')

    for _, vehicle in ipairs(GetAllVehicles()) do
        local drawn = GetVehicleNumberPlateText(vehicle)
        if drawn and drawn:upper():match('^%s*(.-)%s*$') == wanted then return true end
    end

    return false
end

--- Is a player in any seat? A car is never deleted from under somebody.
local function occupiedByPlayer(entity)
    for seat = -1, 14 do
        local ped = GetPedInVehicleSeat(entity, seat)
        if ped and ped ~= 0 and IsPedAPlayer(ped) then return true end
    end

    return false
end

local function positionOf(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end

    return GetEntityCoords(ped)
end

--- GTA vehicle class 18: emergency. A patrol car or an ambulance is not
--- somebody's abandoned vehicle.
local EMERGENCY_CLASS <const> = 18

--- Entities a tow is already working on. The record is written between the
--- checks and the delete, and that write yields; a second press in that
--- window must not make a second hold on the same car.
local towing = {}

--- What the tow leaves in the audit trail: enough to say what was removed,
--- from where, and whether the owner's garage was touched.
local towAudit = {}

route.define({
    name = 'impound.tow',
    perm = 'impound.create',
    schema = 'ImpoundTow',
    context = { onDuty = true },
    writes = true,
    sensitive = true,
    limit = { per = 6, window = 60 },
    audit = 'impound.created',
    subjectType = VEHICLE,
    auditDetail = function(input, result)
        local detail = result and towAudit[result.id] or {}
        if result then towAudit[result.id] = nil end

        detail.heldReasonKey = input.heldReasonKey
        detail.netId = input.netId
        detail.towed = true
        detail.plate = result and result.plate or nil
        detail.despawned = result and result.despawned == true or false

        return detail
    end,
    handler = function(session, input)
        local entity = NetworkGetEntityFromNetworkId(input.netId)
        if not entity or entity == 0 or not DoesEntityExist(entity) or GetEntityType(entity) ~= 2 then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND, { netId = 'unreachable' })
        end

        -- Same instance as the officer: a car at the same coordinates in
        -- somebody's garage interior is not in front of them.
        if GetEntityRoutingBucket(entity) ~= GetPlayerRoutingBucket(session.src) then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND, { netId = 'unreachable' })
        end

        local here = positionOf(session.src)
        local reach = tonumber(world().range) or 8.0
        if not here or #(GetEntityCoords(entity) - here) > reach then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { netId = 'out_of_range' })
        end

        if occupiedByPlayer(entity) then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { netId = 'occupied' })
        end

        local drawn = GetVehicleNumberPlateText(entity)
        local plate = FredPD.Modules.registry.normalizePlate(drawn)
        if not plate then return route.refuse(FredPD.ErrorCode.NOT_FOUND, { netId = 'unreachable' }) end

        if GetVehicleClass(entity) == EMERGENCY_CLASS then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { netId = 'fleet_vehicle' })
        end

        -- Claimed before the first database call, which yields.
        if towing[entity] then return route.refuse(FredPD.ErrorCode.CONFLICT, { netId = 'in_progress' }) end
        towing[entity] = true

        local model = GetEntityModel(entity)
        local bucket = GetEntityRoutingBucket(entity)

        --- Still the same car, in the same place, with nobody in it? Asked
        --- again after every yield, right before anything irreversible.
        local function stillTowable()
            if not DoesEntityExist(entity) or GetEntityModel(entity) ~= model then return false end
            if GetEntityRoutingBucket(entity) ~= bucket then return false end

            local now = positionOf(session.src)
            if not now or #(GetEntityCoords(entity) - now) > reach then return false end

            return not occupiedByPlayer(entity)
        end

        local ok, result = pcall(function()
            if FredPD.Modules.garageFleet.isOut(plate) then
                return route.refuse(FredPD.ErrorCode.CONFLICT, { netId = 'fleet_vehicle' })
            end

            local coords = GetEntityCoords(entity)

            -- The plate on a car is whatever its owning client set it to. It
            -- is trusted as far as the garage only when the garage row for it
            -- names this model too; otherwise the car is still impounded and
            -- towed, but nobody's garage is touched and no lookout on the
            -- plate's real car is resolved by it.
            local owned = FredPD.Bridge.framework.ownedVehicleExact(drawn)
            local stored = owned and owned.model
            if stored and not tonumber(stored) then stored = GetHashKey(stored) end
            local verified = owned ~= nil and service.sameModel(stored, model)

            local fields = { plate = plate, model = tostring(model), heldReasonKey = input.heldReasonKey }

            local err, why = service.validateCreate(fields)
            if err then return route.refuse(err, why) end

            local row = repo.create(fields, session)
            if not row then return route.refuse(FredPD.ErrorCode.INTERNAL) end

            -- Checked again right before the delete: the record write yielded,
            -- and somebody may have got in or driven off meanwhile.
            local despawned = false
            if world().despawn ~= false and stillTowable() then
                DeleteEntity(entity)
                despawned = not DoesEntityExist(entity)
            end

            -- The garage is marked held only for a verified car that is now
            -- gone -- and not if another car still carries the plate, which
            -- would be the real one or a clone. The row naming the garage
            -- plate is written first: a garage write that then fails leaves
            -- a restore that simply does not match, never a car held forever
            -- by no impound at all.
            local garageMarked = false
            if despawned then
                local mark = verified and not plateInWorld(owned.plate)
                repo.markTowed(row.id, session.agencyId, mark and owned.plate or nil)

                if mark then
                    garageMarked = FredPD.Bridge.framework.setVehicleStored(
                        owned.plate, world().storedWhileImpounded, { isnt = world().storedOnRelease })
                end
            end

            if verified and row.vehicleId then
                TriggerEvent('fredpd:vehicleImpounded', {
                    vehicleId = row.vehicleId,
                    discordId = session.discordId,
                    agencyId = session.agencyId,
                })
            end

            towAudit[row.id] = {
                model = model,
                coords = { x = coords.x, y = coords.y, z = coords.z },
                plateVerified = verified,
                garageMarked = garageMarked,
            }

            return { id = row.id, number = row.number, plate = plate, despawned = despawned }
        end)

        towing[entity] = nil
        if not ok then error(result) end

        return result
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
    auditDetail = function(input, result)
        return {
            id = input.id,
            feePaid = input.feePaid,
            garageRestored = type(result) == 'table' and result.garageRestored == true or false,
        }
    end,
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

        -- Back in the owner's garage, where they collect it -- only for a car
        -- a tow actually took off the street and marked held, only when no
        -- other hold in any agency still has it, and only if the garage row
        -- still reads as held. Anything else would hand out a second copy of
        -- a car that is still parked somewhere.
        local garageRestored = false
        if row.towedAt and row.garagePlate and not repo.otherOpenHold(row.garagePlate, row.id)
            and not plateInWorld(row.garagePlate)
        then
            garageRestored = FredPD.Bridge.framework.setVehicleStored(
                row.garagePlate, world().storedOnRelease, { is = world().storedWhileImpounded })
        end

        return { id = row.id, garageRestored = garageRestored }
    end,
})
