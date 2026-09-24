--- Locations and premises routes (spec 7.6).
---
--- The address index, the hazards on a premise and who holds its keys. Every
--- read goes through `access.read` / `access.filterSearch` under the
--- allowlisted `location` type, because an address can be as sensitive as a
--- person -- a protected witness's flat is exactly that (invariant 4).
---
--- The part an officer meets without opening this screen is
--- `FredPD.Modules.locationsApi`: `premisesAt` finds the premises with standing
--- hazards at a call, once per call, and `visibleTo` narrows them to what one
--- reader may see (`hazardsAt` does both). The CAD call card and the dispatch
--- notice use it, so a dog that bit somebody last week is on the screen before
--- the next unit walks up.

-- luacheck: read globals GetPlayerPed GetEntityCoords

local route = FredPD.Core.route
local repo = FredPD.Repo.locations
local service = FredPD.Modules.locations
local access = FredPD.Repo.access
local accessRules = FredPD.Modules.access

local LOCATION <const> = 'location'

--- Reads a premise this session may read, or refuses. A premise the reader
--- may not know exists (4.5 "hidden") is refused exactly as one that does not
--- exist; only a stubbed one says it is restricted, so walking the ids cannot
--- map where the protected addresses are.
local function readable(session, id)
    local row = repo.byId(id, session.agencyId)
    if not row then return nil, route.refuse(FredPD.ErrorCode.NOT_FOUND) end

    local allowed = access.read(session, LOCATION, row)
    if allowed then return allowed end

    local visibility = accessRules.visibility(access.reader(session), row)
    return nil, route.refuse(visibility == 'stub' and FredPD.ErrorCode.RESTRICTED or FredPD.ErrorCode.NOT_FOUND)
end

--- Where the officer is standing, read off their ped. The only way a premise
--- gets a position: a client never sends coordinates (invariant 1).
local function positionOf(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end

    local coords = GetEntityCoords(ped)
    return { x = coords.x, y = coords.y, z = coords.z }
end

--- A person for the keyholder list, and how far this reader may see them.
---
--- The person register's own key comes first: an address is readable by a
--- trainee, and the names and numbers of the people who live there are not
--- (invariant 2). Then the record's own access, whose visibility decides
--- whether a refused keyholder is drawn as restricted ('stub') or not at all.
---
--- @return table|nil person, string visibility
local function personRef(session, personId)
    if not FredPD.Core.perms.satisfies(session.permissions, 'rms.person.view') then
        return nil, 'hidden'
    end

    local person, visibility = FredPD.Repo.persons.readPerson(session, personId)
    if not person then return nil, visibility end

    return {
        id = person.id,
        personNumber = person.personNumber,
        firstName = person.firstName,
        lastName = person.lastName,
        phone = person.phone,
    }, 'full'
end

--- Calls at this premise the reader may be shown, newest first: one query,
--- then the CAD module's own read rule over the whole list (dispatch key and
--- clearance), the same one `call.list` applies.
local function historyFor(session, location)
    local calls = FredPD.Cad.board.readable(session, repo.callsAt(session.agencyId, location, 30))
    local out = {}

    for index = 1, math.min(#calls, 15) do
        local call = calls[index]
        out[index] = {
            id = call.id,
            callNumber = call.callNumber,
            type = call.type,
            status = call.status,
            disposition = call.disposition,
            receivedAt = call.receivedAt,
        }
    end

    return out
end

-- -----------------------------------------------------------------------------
-- Reads
-- -----------------------------------------------------------------------------

route.define({
    name = 'location.search',
    perm = 'rms.location.view',
    schema = 'LocationSearch',
    handler = function(session, input)
        local term = service.normalizeLabel(input.term)
        local rows = repo.search(session.agencyId, term, input.limit or 50)

        return { locations = access.filterSearch(session, LOCATION, rows) }
    end,
})

route.define({
    name = 'location.get',
    perm = 'rms.location.view',
    schema = 'LocationGet',
    handler = function(session, input)
        local location, refusal = readable(session, input.id)
        if not location then return refusal end

        local keyholders = {}
        for _, holder in ipairs(repo.keyholders(location.id, session.agencyId)) do
            local person, visibility = personRef(session, holder.personId)

            -- A keyholder in a stubbed compartment is shown as restricted: the
            -- premise has one, and whom to ask is somebody else's question.
            -- One the reader may not know of leaves no trace (4.5).
            if person then
                keyholders[#keyholders + 1] = { role = holder.role, person = person }
            elseif visibility == 'stub' then
                keyholders[#keyholders + 1] = { role = holder.role, restricted = true }
            end
        end

        return {
            location = location,
            hazards = repo.hazards(location.id, session.agencyId),
            keyholders = keyholders,
            history = historyFor(session, location),
        }
    end,
})

-- -----------------------------------------------------------------------------
-- Writes
-- -----------------------------------------------------------------------------

route.define({
    name = 'location.create',
    perm = 'rms.location.edit',
    schema = 'LocationCreate',
    writes = true,
    limit = { per = 10, window = 60 },
    audit = 'location.created',
    subjectType = LOCATION,
    auditDetail = function(input) return { kind = input.kind, here = input.here == true } end,
    handler = function(session, input)
        local label = service.normalizeLabel(input.label)
        if not label then return route.refuse(FredPD.ErrorCode.INVALID, { label = 'required' }) end

        if not accessRules.canClassify(access.reader(session), input.classification) then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { classification = 'over_clearance' })
        end

        local fields = {
            label = label,
            kind = input.kind,
            notes = input.notes,
            radius = input.radius or service.DEFAULT_RADIUS,
            classification = input.classification,
        }

        if input.here then
            local at = positionOf(session.src)
            if not at then return route.refuse(FredPD.ErrorCode.CONFLICT, { here = 'no_position' }) end
            fields.x, fields.y, fields.z = at.x, at.y, at.z
        end

        local id = repo.create(session.agencyId, fields, session.discordId)
        if not id then return route.refuse(FredPD.ErrorCode.INTERNAL) end

        return { id = id }
    end,
})

route.define({
    name = 'location.update',
    perm = 'rms.location.edit',
    schema = 'LocationUpdate',
    writes = true,
    audit = 'location.updated',
    subjectType = LOCATION,
    auditDetail = function(input) return { id = input.id, here = input.here == true } end,
    handler = function(session, input)
        local location, refusal = readable(session, input.id)
        if not location then return refusal end

        local fields = { kind = input.kind, notes = input.notes, radius = input.radius }

        if input.label ~= nil then
            fields.label = service.normalizeLabel(input.label)
            if not fields.label then return route.refuse(FredPD.ErrorCode.INVALID, { label = 'required' }) end
        end

        if input.here then
            local at = positionOf(session.src)
            if not at then return route.refuse(FredPD.ErrorCode.CONFLICT, { here = 'no_position' }) end
            fields.x, fields.y, fields.z = at.x, at.y, at.z
        end

        if repo.update(location.id, session.agencyId, input.version, fields, session.discordId) == 0 then
            return route.refuse(FredPD.ErrorCode.CONFLICT)
        end

        return { id = location.id }
    end,
})

route.define({
    name = 'location.hazard.add',
    perm = 'rms.location.hazard.edit',
    schema = 'LocationHazardAdd',
    writes = true,
    limit = { per = 10, window = 60 },
    audit = 'location.hazard.added',
    subjectType = LOCATION,
    auditDetail = function(input, result)
        return { kind = input.kind, hazardId = type(result) == 'table' and result.hazardId or nil }
    end,
    handler = function(session, input)
        local location, refusal = readable(session, input.locationId)
        if not location then return refusal end

        local id = repo.addHazard(location.id, session.agencyId, input.kind, input.note, input.days,
            session.discordId)
        if not id then return route.refuse(FredPD.ErrorCode.INTERNAL) end

        -- `id` is the premise, so the audit row is filed under it.
        return { id = location.id, hazardId = id }
    end,
})

route.define({
    name = 'location.hazard.cancel',
    perm = 'rms.location.hazard.edit',
    schema = 'LocationHazardCancel',
    writes = true,
    audit = 'location.hazard.cancelled',
    subjectType = LOCATION,
    auditDetail = function(input) return { hazardId = input.id } end,
    handler = function(session, input)
        local hazard = repo.hazardById(input.id, session.agencyId)
        if not hazard then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

        local location, refusal = readable(session, hazard.locationId)
        if not location then return refusal end

        if repo.cancelHazard(hazard.id, session.agencyId, session.discordId) == 0 then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { _input = 'already_cancelled' })
        end

        return { id = location.id, hazardId = hazard.id }
    end,
})

route.define({
    name = 'location.keyholder.set',
    perm = 'rms.location.edit',
    schema = 'LocationKeyholderSet',
    writes = true,
    audit = 'location.keyholder.set',
    subjectType = LOCATION,
    auditDetail = function(input)
        return { locationId = input.locationId, personId = input.personId, role = input.role }
    end,
    handler = function(session, input)
        local location, refusal = readable(session, input.locationId)
        if not location then return refusal end

        -- Linking a person is reading them (invariant 4): a reader who may not
        -- see a record must not learn it exists by attaching it somewhere.
        if not personRef(session, input.personId) then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND, { personId = 'unknown' })
        end

        repo.setKeyholder(location.id, session.agencyId, input.personId, input.role, session.discordId)

        return { id = location.id }
    end,
})

route.define({
    name = 'location.keyholder.remove',
    perm = 'rms.location.edit',
    schema = 'LocationKeyholderRemove',
    writes = true,
    -- A hard delete: a stale permission snapshot must not produce one (4.2).
    sensitive = true,
    audit = 'location.keyholder.removed',
    subjectType = LOCATION,
    auditDetail = function(input) return { locationId = input.locationId, personId = input.personId } end,
    handler = function(session, input)
        local location, refusal = readable(session, input.locationId)
        if not location then return refusal end

        -- Only a keyholder this reader can see may be unlinked. Otherwise the
        -- answer would say which id is the hidden one -- and remove it, with
        -- no way back for somebody who cannot read the person to relink them.
        if not personRef(session, input.personId)
            or repo.removeKeyholder(location.id, session.agencyId, input.personId) == 0
        then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND, { personId = 'unknown' })
        end

        return { id = location.id }
    end,
})

-- -----------------------------------------------------------------------------
-- For the call card and the dispatch notice
-- -----------------------------------------------------------------------------

--- The premises a call is at that carry standing hazards, with those
--- hazards. Worked out once per call; `visibleTo` then decides per reader.
---
--- @param agencyId string
--- @param call table { x, y, locationText }
--- @return table list of premise rows, each with `.hazards`
local function premisesAt(agencyId, call)
    if type(call) ~= 'table' then return {} end

    local candidates = {}

    if call.x and call.y then
        for _, row in ipairs(repo.near(agencyId, call.x, call.y, service.MAX_RADIUS)) do
            candidates[#candidates + 1] = row
        end
    end

    local text = service.normalizeLabel(call.locationText)
    if text then
        for _, row in ipairs(repo.byLabel(agencyId, text)) do
            candidates[#candidates + 1] = row
        end
    end

    local premises = service.premisesFor(candidates, call)
    if #premises == 0 then return {} end

    local ids, byId = {}, {}
    for index, location in ipairs(premises) do
        ids[index] = location.id
        location.hazards = {}
        byId[location.id] = location
    end

    for _, hazard in ipairs(repo.liveHazards(ids, agencyId)) do
        local location = byId[hazard.locationId]
        location.hazards[#location.hazards + 1] = { kind = hazard.kind, note = hazard.note }
    end

    local out = {}
    for _, location in ipairs(premises) do
        if #location.hazards > 0 then out[#out + 1] = location end
    end

    return out
end

--- Those premises this session may read, shaped for the card.
---
--- The address register's own key first, so a session refused `location.get`
--- is not handed the same content on a call card (invariant 2). Then one
--- `filterSearch` over the list, which also audits a read that reached a
--- restricted premise (invariant 11); a stubbed or hidden premise is dropped
--- -- its label and notes are exactly what the stub withholds.
local function visibleTo(session, premises)
    if #premises == 0 then return {} end
    if not FredPD.Core.perms.satisfies(session.permissions, 'rms.location.view') then return {} end

    local rows = {}
    for index, location in ipairs(premises) do
        local copy = {}
        for key, value in pairs(location) do
            if key ~= 'hazards' then copy[key] = value end
        end
        rows[index] = copy
    end

    local byId = {}
    for _, location in ipairs(premises) do byId[location.id] = location end

    local out = {}
    for _, row in ipairs(access.filterSearch(session, LOCATION, rows)) do
        if row.id and not row.restricted then
            out[#out + 1] = {
                locationId = row.id,
                label = row.label,
                hazards = byId[row.id].hazards,
            }
        end
    end

    return out
end

FredPD.Modules.locationsApi = {
    premisesAt = premisesAt,
    visibleTo = visibleTo,
    --- Both at once, for a single reader (the call card).
    hazardsAt = function(session, call)
        return visibleTo(session, premisesAt(session.agencyId, call))
    end,
}
