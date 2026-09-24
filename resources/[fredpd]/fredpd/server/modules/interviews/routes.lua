--- Field interview cards and stop data routes (spec 7.14).
---
--- A card and a stop both name people and vehicles, and every one they name
--- is read through its own access check before it is linked (invariant 4): a
--- card must not be a way to learn that a hidden person exists. Both take the
--- officer's position and current call from the server, never from input.

-- luacheck: read globals GetPlayerPed GetEntityCoords NetworkGetEntityFromNetworkId
-- luacheck: read globals DoesEntityExist GetEntityType GetVehicleNumberPlateText

local route = FredPD.Core.route
local repo = FredPD.Repo.interviews
local service = FredPD.Modules.interviews
local access = FredPD.Repo.access
local accessRules = FredPD.Modules.access

local FI <const> = 'fi_card'
local STOP <const> = 'stop'

local function positionOf(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end

    local coords = GetEntityCoords(ped)
    return { x = coords.x, y = coords.y, z = coords.z }
end

--- The call this officer is on right now, if any.
local function currentCallId(session)
    local assignment = FredPD.Repo.cad.activeAssignment(session.agencyId, session.discordId)
    return assignment and assignment.callId or nil
end

--- A person the session may read, shaped for a card, or nil.
local function personRef(session, personId)
    if not personId then return nil end
    if not FredPD.Core.perms.satisfies(session.permissions, 'rms.person.view') then return nil end

    local person = FredPD.Repo.persons.readPerson(session, personId)
    if not person then return nil end

    return {
        id = person.id,
        personNumber = person.personNumber,
        firstName = person.firstName,
        lastName = person.lastName,
    }
end

--- A vehicle the session may read, or nil.
local function vehicleRef(session, vehicleId)
    if not vehicleId then return nil end
    if not FredPD.Core.perms.satisfies(session.permissions, 'rms.vehicle.view') then return nil end

    local vehicle = FredPD.Repo.registry.findVehicle(session.agencyId, { id = vehicleId })
    if not vehicle then return nil end

    local allowed = access.read(session, 'vehicle', vehicle)
    if not allowed then return nil end

    return { id = allowed.id, plate = allowed.plate, model = allowed.model }
end

--- The people and vehicles a page of rows names that this reader may read,
--- keyed by id: one query and one access pass per kind for the whole page,
--- never one read per row (spec 12). An id the reader may not read -- hidden,
--- stubbed, or no permission to read that register at all -- is simply absent.
---
--- @param personIds number[]
--- @param vehicleIds number[]
--- @return table persons, table vehicles
local function readableRefs(session, personIds, vehicleIds)
    local persons, vehicles = {}, {}
    local perms = FredPD.Core.perms

    if #personIds > 0 and perms.satisfies(session.permissions, 'rms.person.view') then
        local rows = repo.personsByIds(session.agencyId, personIds)
        for _, row in ipairs(rows) do row.recordType = 'person' end

        for _, row in ipairs(access.filterSearch(session, 'person', rows)) do
            if row.id then
                persons[row.id] = {
                    id = row.id,
                    personNumber = row.personNumber,
                    firstName = row.firstName,
                    lastName = row.lastName,
                }
            end
        end
    end

    if #vehicleIds > 0 and perms.satisfies(session.permissions, 'rms.vehicle.view') then
        local rows = repo.vehiclesByIds(session.agencyId, vehicleIds)
        for _, row in ipairs(rows) do row.recordType = 'vehicle' end

        for _, row in ipairs(access.filterSearch(session, 'vehicle', rows)) do
            if row.id then vehicles[row.id] = { id = row.id, plate = row.plate, model = row.model } end
        end
    end

    return persons, vehicles
end

--- The distinct non-nil values of one field across a page of rows.
local function idsOf(rows, field, into)
    local out, seen = into or {}, {}
    for _, id in ipairs(out) do seen[id] = true end

    for _, row in ipairs(rows) do
        local id = row[field]
        if id and not seen[id] then
            seen[id] = true
            out[#out + 1] = id
        end
    end

    return out
end

--- Adds the names a reader may see to cards on their way out. A subject the
--- reader may not read is dropped from the card, not named.
local function shapeCards(session, cards, withAssociates)
    local associatesOf = {}
    local personIds = idsOf(cards, 'personId')

    if withAssociates then
        for _, card in ipairs(cards) do
            associatesOf[card.id] = repo.fiAssociates(card.id)
            idsOf(associatesOf[card.id], 'personId', personIds)
        end
    end

    local persons, vehicles = readableRefs(session, personIds, idsOf(cards, 'vehicleId'))

    for _, card in ipairs(cards) do
        card.person = card.personId and persons[card.personId] or nil
        card.vehicle = card.vehicleId and vehicles[card.vehicleId] or nil
        card.personId, card.vehicleId = nil, nil

        if withAssociates then
            local associates = {}
            for _, row in ipairs(associatesOf[card.id]) do
                local person = persons[row.personId]
                if person then associates[#associates + 1] = person end
            end
            card.associates = associates
        end
    end

    return cards
end

-- -----------------------------------------------------------------------------
-- Field interview cards
-- -----------------------------------------------------------------------------

route.define({
    name = 'fi.create',
    perm = 'rms.fi.create',
    schema = 'FiCreate',
    writes = true,
    limit = { per = 10, window = 60 },
    audit = 'fi.created',
    subjectType = FI,
    auditDetail = function(input, result)
        return {
            reason = input.reason,
            personId = input.personId,
            vehicleId = input.vehicleId,
            associates = type(result) == 'table' and result.associates or nil,
        }
    end,
    handler = function(session, input)
        if not service.hasSubject(input) then
            return route.refuse(FredPD.ErrorCode.INVALID, { personId = 'needs_subject' })
        end

        local associates, why = service.associateIds(input.associateIds, input.personId)
        if not associates then return route.refuse(FredPD.ErrorCode.INVALID, { associateIds = why }) end

        -- Everybody and everything the card names must be readable by the
        -- officer writing it, answered the same way as a record that does not
        -- exist.
        if input.personId and not personRef(session, input.personId) then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND, { personId = 'unknown' })
        end

        if input.vehicleId and not vehicleRef(session, input.vehicleId) then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND, { vehicleId = 'unknown' })
        end

        for _, personId in ipairs(associates) do
            if not personRef(session, personId) then
                return route.refuse(FredPD.ErrorCode.NOT_FOUND, { associateIds = 'unknown' })
            end
        end

        if not accessRules.canClassify(access.reader(session), input.classification) then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { classification = 'over_clearance' })
        end

        local fields = {
            personId = input.personId,
            vehicleId = input.vehicleId,
            callId = currentCallId(session),
            reason = input.reason,
            narrative = input.narrative,
            locationText = input.locationText,
            classification = input.classification,
        }

        if input.here then
            local at = positionOf(session.src)
            if at then fields.x, fields.y, fields.z = at.x, at.y, at.z end
        end

        local id = repo.fiCreate(session.agencyId, fields, associates, session.discordId)
        if not id then return route.refuse(FredPD.ErrorCode.INTERNAL) end

        return { id = id, associates = #associates }
    end,
})

route.define({
    name = 'fi.list',
    perm = 'rms.fi.view',
    schema = 'FiList',
    limit = { per = 20, window = 60 },
    handler = function(session, input)
        -- Reading the cards about a person is reading that person.
        if input.personId and not personRef(session, input.personId) then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND, { personId = 'unknown' })
        end

        if input.vehicleId and not vehicleRef(session, input.vehicleId) then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND, { vehicleId = 'unknown' })
        end

        local rows = repo.fiList(session.agencyId, {
            personId = input.personId,
            vehicleId = input.vehicleId,
            createdBy = input.mine and session.discordId or nil,
        }, input.limit or 50)

        local cards = access.filterSearch(session, FI, rows)

        local open = {}
        for _, card in ipairs(cards) do
            if card.id then open[#open + 1] = card end
        end
        shapeCards(session, open, false)

        return { cards = cards }
    end,
})

route.define({
    name = 'fi.get',
    perm = 'rms.fi.view',
    schema = 'FiGet',
    handler = function(session, input)
        local card = repo.fiById(input.id, session.agencyId)
        if not card then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

        local allowed = access.read(session, FI, card)
        if not allowed then
            local visibility = accessRules.visibility(access.reader(session), card)
            return route.refuse(visibility == 'stub' and FredPD.ErrorCode.RESTRICTED or FredPD.ErrorCode.NOT_FOUND)
        end

        return { card = shapeCards(session, { allowed }, true)[1] }
    end,
})

-- -----------------------------------------------------------------------------
-- Stops
-- -----------------------------------------------------------------------------

--- The registered vehicle in front of the officer, from its network id: the
--- plate is read off the car by the server (7.14 via ox_target).
local function vehicleFromNetId(session, netId)
    local entity = NetworkGetEntityFromNetworkId(netId)
    if not entity or entity == 0 or not DoesEntityExist(entity) or GetEntityType(entity) ~= 2 then
        return nil, 'unreachable'
    end

    local here = positionOf(session.src)
    local reach = tonumber((FredPD.Config.server.field or {}).range) or 5.0
    local coords = GetEntityCoords(entity)
    if not here then return nil, 'out_of_range' end

    local dx, dy, dz = coords.x - here.x, coords.y - here.y, coords.z - here.z
    if dx * dx + dy * dy + dz * dz > reach * reach then return nil, 'out_of_range' end

    local plate = FredPD.Modules.registry.normalizePlate(GetVehicleNumberPlateText(entity))
    local vehicle = plate and FredPD.Repo.registry.findVehicle(session.agencyId, { plate = plate })

    -- A car nobody registered is still a stop; it simply names no vehicle.
    if not vehicle or not access.read(session, 'vehicle', vehicle) then return nil end

    return vehicle.id
end

route.define({
    name = 'stop.create',
    perm = 'rms.stops.create',
    -- A stop is made on duty, and its netId path reads a car off the street.
    context = { onDuty = true },
    schema = 'StopCreate',
    writes = true,
    limit = { per = 10, window = 60 },
    audit = 'stop.recorded',
    subjectType = STOP,
    auditDetail = function(input)
        return { kind = input.kind, reason = input.reason, search = input.search, result = input.result }
    end,
    handler = function(session, input)
        local vehicleId = input.vehicleId

        if input.netId then
            local found, why = vehicleFromNetId(session, input.netId)
            if why then return route.refuse(FredPD.ErrorCode.CONFLICT, { netId = why }) end
            vehicleId = found
        elseif vehicleId and not vehicleRef(session, vehicleId) then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND, { vehicleId = 'unknown' })
        end

        if input.personId and not personRef(session, input.personId) then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND, { personId = 'unknown' })
        end

        local at = positionOf(session.src) or {}

        local id = repo.stopCreate(session.agencyId, {
            kind = input.kind,
            reason = input.reason,
            search = input.search,
            result = input.result,
            personId = input.personId,
            vehicleId = vehicleId,
            callId = currentCallId(session),
            x = at.x, y = at.y, z = at.z,
        }, session.discordId)
        if not id then return route.refuse(FredPD.ErrorCode.INTERNAL) end

        return { id = id }
    end,
})

route.define({
    name = 'stop.list',
    perm = 'rms.stops.view',
    schema = 'StopList',
    limit = { per = 20, window = 60 },
    handler = function(session, input)
        local rows = repo.stopList(session.agencyId, {
            createdBy = input.mine and session.discordId or nil,
        }, input.limit or 50)

        local stops = access.filterSearch(session, STOP, rows)

        -- The plate is the vehicle record's, shown only when this reader may
        -- read that record; the person is never named on the stop list.
        local open = {}
        for _, stop in ipairs(stops) do
            if stop.id then open[#open + 1] = stop end
        end

        local _, vehicles = readableRefs(session, {}, idsOf(open, 'vehicleId'))

        for _, stop in ipairs(open) do
            local vehicle = stop.vehicleId and vehicles[stop.vehicleId]
            stop.plate = vehicle and vehicle.plate or nil
            stop.personId, stop.vehicleId = nil, nil
        end

        return { stops = stops }
    end,
})
