--- Field routes (spec 7.2, 7.4): the person or the vehicle in front of the
--- officer, resolved on the server.
---
--- The client names *who* by server id and *what* by network id, and nothing
--- else. The server reads the character behind the id, the plate off the
--- entity, and both positions itself, and refuses anything out of reach. A
--- client cannot look somebody up by standing next to somebody else, and
--- cannot run a plate that is not on the car beside it (invariant 1).
---
--- **Nobody is identified without their say.** Checking an ID asks the
--- player, who can refuse; only a person already held in custody is
--- identified without asking (the gate `forensics.identity.scan` uses). Who
--- refuses can be arrested as unidentified and is identified at booking by
--- their prints.
---
--- **Strangers are registered, not dead ends.** A character who shows an ID
--- the agency has never seen is registered from what that ID says; a car
--- FredPD has never seen but ESX says somebody owns is registered to that
--- owner. Both are system acts on what the game already knows, audited, and
--- never an officer typing a new file into existence.
--- The answer is then the ordinary access-checked record id -- what the
--- officer does next (a query, a citation, an arrest) goes through that
--- route's own checks.
---
--- The persons and registry repos are reached through their own read and
--- create entry points (`readPerson`, `createPerson`, `byIdentifier`, `findVehicle`,
--- `registerVehicle`), the same way `frihet` and `forensics` already reach
--- `readPerson`: those are the one definition of how a record is read and
--- how its number is allocated, and a second copy here would drift.

local route = FredPD.Core.route
local service = FredPD.Modules.field
local registry = FredPD.Modules.registry
local persons = FredPD.Repo.persons
local vehicles = FredPD.Repo.registry
local access = FredPD.Repo.access
local framework = FredPD.Bridge.framework

local VEHICLE <const> = 'vehicle'

local function range()
    local config = FredPD.Config.server.field or {}
    return tonumber(config.range) or service.DEFAULT_RANGE
end

--- Where a player is, according to the server. Never a coordinate from input.
local function positionOf(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end

    return GetEntityCoords(ped)
end

--- Is this person held under an open custody chain? A detained person's
--- identity is established without asking them -- the same gate
--- `forensics.identity.scan` puts on a live print scan (8.8).
local function detained(agencyId, personId)
    local chains = FredPD.Repo.frihet.list(agencyId, { personId = personId }, 5) or {}

    for index = 1, #chains do
        if FredPD.Modules.frihet.isOpen(chains[index]) then return true end
    end

    return false
end

--- Registers somebody the agency has never met, from their own ID card.
---
--- Never tied to an existing record by name and date of birth: both are
--- chosen by the player, and matching on them is how a look-alike character
--- takes over somebody else's file. Two records for one person is the honest
--- failure; booking's ten-print is what links identities (8.8).
---
--- Read back by identifier (unique per agency), not by `createPerson`'s own
--- read-back, which can hand one officer's concurrent registration to
--- another. Audited here, whatever the route answers afterwards.
local function register(session, fields)
    persons.createPerson(session.agencyId, fields, session.discordId)

    local personId = persons.byIdentifier(session.agencyId, fields.identifier)

    if personId then
        FredPD.Core.audit.write({
            action = 'person.created',
            discordId = session.discordId,
            agencyId = session.agencyId,
            subjectType = 'person',
            subjectId = tostring(personId),
            detail = { source = 'field_id_check' },
        })
    end

    return personId
end

--- Range and presence, shared by both person routes.
local function reach(session, targetId)
    if targetId == session.src then
        return route.refuse(FredPD.ErrorCode.INVALID, { targetId = 'not_allowed' })
    end

    local there, here = positionOf(targetId), positionOf(session.src)
    if not there or not here then
        return route.refuse(FredPD.ErrorCode.NOT_FOUND, { targetId = 'unreachable' })
    end

    if not service.withinRange(there, here, range()) then
        return route.refuse(FredPD.ErrorCode.CONFLICT, { targetId = 'out_of_range' })
    end

    return nil
end

route.define({
    name = 'field.person.resolve',
    -- Checking somebody's ID is a person query (7.2); the key that already
    -- says an officer may run one is the key that says they may do this.
    perm = 'query.person.run',
    schema = 'FieldPersonResolve',
    context = { onDuty = true },
    -- It can register a person, so it is a write: refused in read-only mode.
    writes = true,
    limit = { per = 20, window = 60 },
    audit = 'field.person.resolved',
    subjectType = 'person',
    auditDetail = function(input, result)
        return { targetId = input.targetId, registered = result and result.registered == true or false }
    end,
    handler = function(session, input)
        local refusal = reach(session, input.targetId)
        if refusal then return refusal end

        local fields = service.personFields(framework.getIdentity(input.targetId))
        if not fields then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND, { targetId = 'unreachable' })
        end

        local personId = persons.byIdentifier(session.agencyId, fields.identifier)

        -- Asked before anything is written or read: a refusal must leave no
        -- record behind and tell the officer nothing about the person.
        if not (personId and detained(session.agencyId, personId)) then
            -- Nobody is identified by standing near an officer: a masked
            -- suspect who will not show ID stays unknown until arrested and
            -- fingerprinted (spec 11.1, 8.8).
            if not FredPD.Field.consent.ask(input.targetId, session.callsign) then
                return route.refuse(FredPD.ErrorCode.CONFLICT, { targetId = 'refused' })
            end
        end

        local registered = false
        if not personId then
            personId = register(session, fields)
            registered = personId ~= nil
        end

        if not personId then return route.refuse(FredPD.ErrorCode.INTERNAL) end

        -- The same access-checked read every other path uses. A record the
        -- officer may not know exists (4.5 "hidden") is answered exactly as a
        -- person with no ID would be, so the refusal is not an oracle for
        -- protected identities; a stubbed one says it is restricted.
        local person, visibility = persons.readPerson(session, personId)
        if not person then
            if visibility == 'stub' then
                return route.refuse(FredPD.ErrorCode.RESTRICTED, { targetId = 'restricted' })
            end

            return route.refuse(FredPD.ErrorCode.NOT_FOUND, { targetId = 'unreachable' })
        end

        return {
            id = person.id,
            personNumber = person.personNumber,
            firstName = person.firstName,
            lastName = person.lastName,
            registered = registered,
            licence = FredPD.Modules.ordningsbotLicence and FredPD.Modules.ordningsbotLicence.standingFor(session, person.id)
                or nil,
        }
    end,
})

route.define({
    name = 'field.person.unidentified',
    -- Only for an arrest: somebody who will not show ID is gripen on the
    -- ground `identitet_oklar` and identified at booking by their prints.
    perm = 'frihet.gripande',
    schema = 'FieldPersonResolve',
    context = { onDuty = true },
    writes = true,
    limit = { per = 5, window = 60 },
    audit = 'field.person.unidentified',
    subjectType = 'person',
    auditDetail = function(input) return { targetId = input.targetId } end,
    handler = function(session, input)
        local refusal = reach(session, input.targetId)
        if refusal then return refusal end

        -- The arrested character, recorded out of sight (0028) so booking's
        -- ten-print can refuse any other ped. Read before anything is written.
        local character = framework.getIdentity(input.targetId)
        local identifier = character and character.identifier
        if type(identifier) ~= 'string' or identifier == '' then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND, { targetId = 'unreachable' })
        end

        -- A record with no name and no identifier: nothing about them is known
        -- to the officer yet. Booking's ten-print is what ties it to who they
        -- are.
        local personId = persons.createPerson(session.agencyId, {}, session.discordId)
        if not personId then return route.refuse(FredPD.ErrorCode.INTERNAL) end

        local person = persons.readPerson(session, personId)

        -- `createPerson` reads its row back as "this officer's newest person".
        -- A registration of theirs made in the same instant would be an
        -- identified record; an arrest must never land on that one.
        if not person or person.firstName or person.lastName then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { targetId = 'retry' })
        end

        -- Two unidentified arrests by one officer in the same instant can
        -- read back the same empty record; the second pending row is then
        -- refused by its primary key, and that arrest must not go ahead.
        if persons.setPendingIdentity(session.agencyId, personId, identifier, session.discordId) ~= 1 then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { targetId = 'retry' })
        end

        FredPD.Core.audit.write({
            action = 'person.created',
            discordId = session.discordId,
            agencyId = session.agencyId,
            subjectType = 'person',
            subjectId = tostring(personId),
            detail = { source = 'field_unidentified_arrest' },
        })

        return { id = person.id, personNumber = person.personNumber }
    end,
})

--- The asked player's own answer to "may I see your ID?" (consent.lua). A
--- public route, because the player asked is usually not an officer and has
--- no session: the token and the sender are the whole check, and the handler
--- touches no record.
route.public({
    name = 'field.person.consent',
    schema = 'FieldPersonConsent',
    limit = { per = 10, window = 60 },
    handler = function(src, input)
        return { accepted = FredPD.Field.consent.answer(src, input.token, input.shown) }
    end,
})

route.define({
    name = 'field.vehicle.resolve',
    perm = 'query.vehicle.run',
    schema = 'FieldVehicleResolve',
    context = { onDuty = true },
    writes = true,
    limit = { per = 20, window = 60 },
    audit = 'field.vehicle.resolved',
    subjectType = VEHICLE,
    auditDetail = function(_input, result)
        return {
            plate = result and result.plate or nil,
            registered = result and result.registered == true or false,
        }
    end,
    handler = function(session, input)
        local entity = NetworkGetEntityFromNetworkId(input.netId)
        if not entity or entity == 0 or not DoesEntityExist(entity) or GetEntityType(entity) ~= 2 then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND, { netId = 'unreachable' })
        end

        if not service.withinRange(GetEntityCoords(entity), positionOf(session.src), range()) then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { netId = 'out_of_range' })
        end

        -- Read off the entity by the server. The plate an officer runs is the
        -- plate on the car, not a plate the client says is on it.
        local drawn = GetVehicleNumberPlateText(entity)
        local plate = registry.normalizePlate(drawn)
        if not plate then return route.refuse(FredPD.ErrorCode.NOT_FOUND, { netId = 'unreachable' }) end

        local vehicle = vehicles.findVehicle(session.agencyId, { plate = plate })
        local registered = false

        if not vehicle then
            local owned = framework.ownedVehicleByPlate(drawn, plate)

            if owned and type(owned.owner) == 'string' and owned.owner ~= '' then
                vehicle = vehicles.registerVehicle(session.agencyId, {
                    plate = plate,
                    ownerPersonId = persons.byIdentifier(session.agencyId, owned.owner),
                    ownerIdentifier = owned.owner,
                    registrationStatus = 'valid',
                }, session.discordId)

                registered = vehicle ~= nil

                -- Registered by a check made at the same moment. Theirs stands.
                vehicle = vehicle or vehicles.findVehicle(session.agencyId, { plate = plate })
            end
        end

        -- Nobody owns this car: an NPC's, or one spawned by a script. That is
        -- an answer too, and the officer is told the plate.
        if not vehicle then return { plate = plate, unregistered = true } end

        -- A vehicle the officer may not know exists (4.5 "hidden") answers
        -- exactly as an unowned car does, so an unmarked car or a surveillance
        -- target is not revealed by the refusal. A stubbed one says so.
        local readable = access.read(session, VEHICLE, vehicle)
        if not readable then
            local visibility = FredPD.Modules.access.visibility(access.reader(session), vehicle)
            if visibility == 'stub' then
                return route.refuse(FredPD.ErrorCode.RESTRICTED, { netId = 'restricted' })
            end

            return { plate = plate, unregistered = true }
        end

        return { id = readable.id, plate = plate, registered = registered }
    end,
})
