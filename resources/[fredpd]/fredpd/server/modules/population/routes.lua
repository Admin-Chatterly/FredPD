--- The population register: opening a citizen or a car nobody has a record of
--- yet (see `service.lua`, ADR-026).
---
--- Two routes, and the two lookups person, vehicle and unified searches use
--- to show what is not yet on file.
---
--- **Who.** `population.search`, seeded to patrol and supervisor: the
--- officers who meet citizens. Not to a read-only role -- opening creates a
--- record -- and only on duty, a few at a time, the way `field.person.resolve`
--- registers somebody from their own ID card.
---
--- **The record is the framework's, copied once.** A suggestion carries a
--- reference, never the framework's key: opening takes the reference, the
--- server looks up what it offered this officer, and reads the character or
--- the car again itself. Only what was offered can be opened, and the
--- officer types nothing into the record. Every later edit is an ordinary
--- edit, with its own permission.
---
--- **What it cannot hide.** A key that already has a record is never
--- offered, whatever that record's access, and opening answers through the
--- record's own access-checked read (4.5). But a citizen an officer knows by
--- name, who appears neither among the results nor here, has a record the
--- officer may not see. That is the price of the register listing the whole
--- population, recorded in ADR-026, and why the list is a permission of its
--- own rather than part of reading records.

local route = FredPD.Core.route
local service = FredPD.Modules.population
local repo = FredPD.Repo.population
local framework = FredPD.Bridge.framework

local PERMISSION <const> = 'population.search'

local function persons() return FredPD.Repo.persons end
local function vehicles() return FredPD.Repo.registry end

--- What each officer was offered: reference -> framework key, for a while.
local offered = {}

local function allowed(session)
    return FredPD.Core.perms.satisfies(session.permissions, PERMISSION)
end

--- Characters matching `term` that have no person record here yet.
--- @return table list of { ref, firstName, lastName, dateOfBirth }
local function characters(session, term)
    if not allowed(session) then return {} end
    local text = service.term(term)
    if not text then return {} end

    local rows = framework.searchCharacters(text, service.LIMIT * 3)
    local identifiers = {}
    for _, row in ipairs(rows) do
        if type(row.identifier) == 'string' and row.identifier ~= '' then identifiers[#identifiers + 1] = row.identifier end
    end

    local onFile = repo.identifiersOnFile(session.agencyId, identifiers)
    local now = os.time()
    local out = {}
    for index, row in ipairs(service.notOnFile(rows, function(r) return r.identifier end, onFile)) do
        out[index] = service.person(row, service.remember(offered, session.discordId, 'person', row.identifier, now))
    end
    return out
end

--- Owned vehicles matching `term` that have no vehicle record here yet.
--- @return table list of { ref, plate }
local function ownedVehicles(session, term)
    if not allowed(session) then return {} end
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
    local now = os.time()
    local out = {}
    for index, row in ipairs(service.notOnFile(rows, function(r) return normalize(r.plate) end, onFile)) do
        local plate = normalize(row.plate)
        out[index] = service.vehicle(plate, service.remember(offered, session.discordId, 'vehicle', row.plate, now))
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
    perm = PERMISSION,
    schema = 'PersonFromCharacter',
    context = { onDuty = true },
    writes = true,
    limit = { per = 5, window = 60 },
    audit = 'person.opened_from_population',
    subjectType = 'person',
    auditDetail = function(_input, result)
        return { personId = result and result.id, created = result and result.created == true or false }
    end,
    handler = function(session, input)
        local identifier = service.recall(offered, session.discordId, 'person', input.ref, os.time())
        if not identifier then return route.refuse(FredPD.ErrorCode.NOT_FOUND, { ref = 'unknown' }) end

        local personId = persons().byIdentifier(session.agencyId, identifier)
        local created = false

        if not personId then
            local fields = FredPD.Modules.field.personFields(framework.characterByIdentifier(identifier))
            if not fields then return route.refuse(FredPD.ErrorCode.NOT_FOUND, { ref = 'unknown' }) end

            local written = persons().createPerson(session.agencyId, fields, session.discordId)
            -- Read back by identifier (unique per agency): a concurrent open
            -- of the same citizen lands on the one record, and only the open
            -- that wrote it says so.
            personId = persons().byIdentifier(session.agencyId, identifier)
            if not personId then return route.refuse(FredPD.ErrorCode.INTERNAL) end

            created = written ~= nil and written == personId
            if created then
                FredPD.Core.audit.write({
                    action = 'person.created',
                    discordId = session.discordId,
                    agencyId = session.agencyId,
                    subjectType = 'person',
                    subjectId = tostring(personId),
                    detail = { source = 'population_register' },
                })
            end
        end

        local person, visibility = persons().readPerson(session, personId)
        if not person then return refusal(visibility, 'ref') end

        return { id = person.id, created = created }
    end,
})

route.define({
    name = 'vehicle.fromOwned',
    perm = PERMISSION,
    schema = 'VehicleFromOwned',
    context = { onDuty = true },
    writes = true,
    limit = { per = 5, window = 60 },
    audit = 'vehicle.opened_from_population',
    subjectType = 'vehicle',
    auditDetail = function(_input, result)
        return { vehicleId = result and result.id, created = result and result.created == true or false }
    end,
    handler = function(session, input)
        local drawn = service.recall(offered, session.discordId, 'vehicle', input.ref, os.time())
        local plate = drawn and FredPD.Modules.registry.normalizePlate(drawn)
        if not plate then return route.refuse(FredPD.ErrorCode.NOT_FOUND, { ref = 'unknown' }) end

        local vehicle = vehicles().findVehicle(session.agencyId, { plate = plate })
        local created = false

        if not vehicle then
            local owned = framework.ownedVehicleByPlate(drawn, plate)
            if not owned or type(owned.owner) ~= 'string' or owned.owner == '' then
                return route.refuse(FredPD.ErrorCode.NOT_FOUND, { ref = 'unknown' })
            end

            -- The keeper is linked only when this officer may read the
            -- keeper's record: an owner id that then answers `not_found`
            -- would say that record is hidden (4.5).
            local ownerId = persons().byIdentifier(session.agencyId, owned.owner)
            if ownerId and not persons().readPerson(session, ownerId) then ownerId = nil end

            vehicle = vehicles().registerVehicle(session.agencyId, {
                plate = plate,
                ownerPersonId = ownerId,
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
            return refusal(FredPD.Modules.access.visibility(FredPD.Repo.access.reader(session), vehicle), 'ref')
        end

        return { id = readable.id, created = created }
    end,
})
