--- The population register: opening a citizen or a car nobody has a record of
--- yet (see `service.lua`).
---
--- Two routes, and the two lookups person, vehicle and unified searches use
--- to show what is not yet on file.
---
--- **The record is the framework's, copied once.** Opening a suggestion
--- creates the person or vehicle from what the framework itself holds, read
--- here on the server by the key the suggestion carried -- the officer types
--- nothing into it, the same way `field.person.resolve` registers somebody
--- from their own ID card. Every later edit is an ordinary edit, with its own
--- permission.
---
--- **Nothing hidden is revealed.** A key that already has a record is never
--- offered as missing, whatever that record's access; and opening one answers
--- through the same access-checked read as any other open (4.5).

local route = FredPD.Core.route
local service = FredPD.Modules.population
local repo = FredPD.Repo.population
local framework = FredPD.Bridge.framework

local function persons() return FredPD.Repo.persons end
local function vehicles() return FredPD.Repo.registry end

--- Characters matching `term` that have no person record here yet.
--- @return table list of { identifier, firstName, lastName, dateOfBirth }
local function characters(session, term)
    local text = service.term(term)
    if not text then return {} end

    local rows = framework.searchCharacters(text, service.LIMIT * 3)
    local identifiers = {}
    for _, row in ipairs(rows) do
        if type(row.identifier) == 'string' and row.identifier ~= '' then identifiers[#identifiers + 1] = row.identifier end
    end

    local onFile = repo.identifiersOnFile(session.agencyId, identifiers)
    local out = {}
    for index, row in ipairs(service.notOnFile(rows, function(r) return r.identifier end, onFile)) do
        out[index] = service.person(row)
    end
    return out
end

--- Owned vehicles matching `term` that have no vehicle record here yet.
--- @return table list of { plate }
local function ownedVehicles(session, term)
    local text = service.term(term)
    if not text then return {} end

    local normalize = FredPD.Modules.registry.normalizePlate
    local rows = framework.searchOwnedVehicles(text, service.LIMIT * 3)
    local plates = {}
    for _, row in ipairs(rows) do
        local plate = normalize(row.plate)
        if plate then plates[#plates + 1] = plate end
    end

    local onFile = repo.platesOnFile(session.agencyId, plates)
    local out = {}
    for index, row in ipairs(service.notOnFile(rows, function(r) return normalize(r.plate) end, onFile)) do
        out[index] = service.vehicle(normalize(row.plate))
    end
    return out
end

--- For person.search, vehicle.search and query.run.
FredPD.Modules.populationSearch = { characters = characters, vehicles = ownedVehicles }

--- A refused open, answered the way the record's own read answers it.
local function refusal(visibility, field)
    if visibility == 'stub' then
        return route.refuse(FredPD.ErrorCode.RESTRICTED, { [field] = 'restricted' })
    end
    return route.refuse(FredPD.ErrorCode.NOT_FOUND, { [field] = 'unknown' })
end

route.define({
    name = 'person.fromCharacter',
    -- The permission that showed the suggestion opens it: the record holds
    -- only what the framework already says about the character.
    perm = 'rms.person.view',
    schema = 'PersonFromCharacter',
    writes = true,
    limit = { per = 20, window = 60 },
    audit = 'person.opened_from_population',
    subjectType = 'person',
    auditDetail = function(_input, result)
        return { personId = result and result.id, created = result and result.created == true or false }
    end,
    handler = function(session, input)
        local personId = persons().byIdentifier(session.agencyId, input.identifier)
        local created = false

        if not personId then
            local fields = FredPD.Modules.field.personFields(framework.characterByIdentifier(input.identifier))
            if not fields then return route.refuse(FredPD.ErrorCode.NOT_FOUND, { identifier = 'unknown' }) end

            persons().createPerson(session.agencyId, fields, session.discordId)
            -- Read back by identifier (unique per agency): a concurrent open
            -- of the same citizen lands on the one record.
            personId = persons().byIdentifier(session.agencyId, input.identifier)
            if not personId then return route.refuse(FredPD.ErrorCode.INTERNAL) end

            created = true
            FredPD.Core.audit.write({
                action = 'person.created',
                discordId = session.discordId,
                agencyId = session.agencyId,
                subjectType = 'person',
                subjectId = tostring(personId),
                detail = { source = 'population_register' },
            })
        end

        local person, visibility = persons().readPerson(session, personId)
        if not person then return refusal(visibility, 'identifier') end

        return { id = person.id, created = created }
    end,
})

route.define({
    name = 'vehicle.fromOwned',
    perm = 'rms.vehicle.view',
    schema = 'VehicleFromOwned',
    writes = true,
    limit = { per = 20, window = 60 },
    audit = 'vehicle.opened_from_population',
    subjectType = 'vehicle',
    auditDetail = function(_input, result)
        return { vehicleId = result and result.id, created = result and result.created == true or false }
    end,
    handler = function(session, input)
        local plate = FredPD.Modules.registry.normalizePlate(input.plate)
        if not plate then return route.refuse(FredPD.ErrorCode.INVALID, { plate = 'required' }) end

        local vehicle = vehicles().findVehicle(session.agencyId, { plate = plate })
        local created = false

        if not vehicle then
            local owned = framework.ownedVehicleByPlate(input.plate, plate)
            if not owned or type(owned.owner) ~= 'string' or owned.owner == '' then
                return route.refuse(FredPD.ErrorCode.NOT_FOUND, { plate = 'unknown' })
            end

            vehicle = vehicles().registerVehicle(session.agencyId, {
                plate = plate,
                ownerPersonId = persons().byIdentifier(session.agencyId, owned.owner),
                ownerIdentifier = owned.owner,
                registrationStatus = 'valid',
            }, session.discordId)
            created = vehicle ~= nil

            -- Registered by another open at the same moment: theirs stands.
            vehicle = vehicle or vehicles().findVehicle(session.agencyId, { plate = plate })
            if not vehicle then return route.refuse(FredPD.ErrorCode.INTERNAL) end
        end

        local readable = FredPD.Repo.access.read(session, 'vehicle', vehicle)
        if not readable then
            return refusal(FredPD.Modules.access.visibility(FredPD.Repo.access.reader(session), vehicle), 'plate')
        end

        return { id = readable.id, created = created }
    end,
})
