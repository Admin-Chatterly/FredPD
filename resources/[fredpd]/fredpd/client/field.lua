--- Field actions (spec 7.2, 7.4): what an officer does to the person or the
--- car in front of them, without opening the MDT first.
---
--- Look at somebody (ox_target) and: check their ID, cite them, arrest them,
--- scan their prints, or open their record. Look at a car and: run the
--- plate, cite, or open it. Every one of these is an ordinary route the
--- server checks in full; this file only turns an entity into the server id
--- or network id the server resolves for itself, and draws the answer.
---
--- Nothing here decides anything (invariant 1). What the officer may do is
--- whatever the routes behind these options answer.

local core = FredPD.Client.core
local target = FredPD.Client.target

-- luacheck: read globals NetworkGetPlayerIndexFromPed

local DISTANCE <const> = 2.5

-- -----------------------------------------------------------------------------
-- Entities to ids
-- -----------------------------------------------------------------------------

local function serverIdOf(ped)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return nil end

    local player = NetworkGetPlayerIndexFromPed(ped)
    if not player or player == -1 then return nil end

    local serverId = GetPlayerServerId(player)
    if not serverId or serverId < 1 then return nil end

    return serverId
end

local function netIdOf(vehicle)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return nil end
    if not NetworkGetEntityIsNetworked(vehicle) then return nil end

    return NetworkGetNetworkIdFromEntity(vehicle)
end

--- The street at the officer's feet, for the place of an arrest. A label the
--- officer could have typed; the server records it as text.
local function streetHere()
    local at = GetEntityCoords(PlayerPedId())
    local street, crossing = GetStreetNameAtCoord(at.x, at.y, at.z)
    local name = street and street ~= 0 and GetStreetNameFromHashKey(street) or nil
    local cross = crossing and crossing ~= 0 and GetStreetNameFromHashKey(crossing) or nil

    if not name or name == '' then return nil end
    if cross and cross ~= '' then name = name .. ' / ' .. cross end

    return name:sub(1, 191)
end

--- Calls a route and shows its refusal, so every flow below reads as the
--- happy path.
local function call(name, data)
    local response = core.call(name, data)
    if not response.ok then
        core.showError(response)
        return nil
    end

    return response.data or {}
end

-- -----------------------------------------------------------------------------
-- Hits (the same words the MDT's query screen uses)
-- -----------------------------------------------------------------------------

local function hitText(hit)
    local specific = FredPD.t('query.hit.' .. tostring(hit.kind))
    if specific ~= 'query.hit.' .. tostring(hit.kind) then return specific end

    return FredPD.t('query.hit.' .. tostring(hit.hitType))
end

--- Runs the same query the MDT runs, so the answer, the logging and the
--- access checks are the MDT's own (7.2), and picks the row for this record.
local function queryRecord(term, kind, id)
    local answer = call('query.run', { term = term, type = kind })
    if not answer then return nil end

    for _, row in ipairs(answer.results or {}) do
        if row.id == id then return row end
    end

    return nil
end

local function hitOptions(row, options)
    local hits = row and row.hits or {}

    if #hits == 0 then
        options[#options + 1] = {
            title = FredPD.t('field.noHits'),
            icon = 'circle-check',
            iconColor = '#2e7d32',
            readOnly = true,
        }
    end

    for _, hit in ipairs(hits) do
        options[#options + 1] = {
            title = hitText(hit),
            icon = 'triangle-exclamation',
            iconColor = '#c62828',
            readOnly = true,
        }
    end
end

-- -----------------------------------------------------------------------------
-- Citing and arresting
-- -----------------------------------------------------------------------------

local function confirm(header, content)
    return lib.alertDialog({
        header = header,
        content = content,
        centered = true,
        cancel = true,
        labels = { confirm = FredPD.t('form.confirm'), cancel = FredPD.t('form.cancel') },
    }) == 'confirm'
end

--- The reasons an impound may rest on, in the order the MDT lists them.
local IMPOUND_REASONS <const> = { 'abandoned', 'unregistered', 'dui', 'evidence', 'investigative', 'other' }

--- Impound the car in front of you: pick why, confirm, and it is towed.
--- The server reads the plate off the car and takes it off the street.
local function impound(netId, label)
    local options = {}

    for _, reason in ipairs(IMPOUND_REASONS) do
        options[#options + 1] = {
            title = FredPD.t('impound.held_reason.' .. reason),
            onSelect = function()
                if not confirm(FredPD.t('field.impound.confirmTitle'),
                    FredPD.t('field.impound.confirm', { plate = core.plainText(label) }))
                then
                    return
                end

                local towed = call('impound.tow', { netId = netId, heldReasonKey = reason })
                if towed then
                    core.notify(towed.despawned and 'field.impound.towed' or 'field.impound.recorded',
                        { number = towed.number })
                end
            end,
        }
    end

    lib.registerContext({ id = 'fredpd_field_impound', title = FredPD.t('field.impound.title'), options = options })
    lib.showContext('fredpd_field_impound')
end

--- Stop data (7.14), three quick choices: why, what was searched, how it
--- ended. The server takes the position, the call and -- for a car -- the
--- vehicle from the plate on it.
local STOP_REASONS <const> = {
    'traffic_violation', 'equipment_fault', 'suspicious', 'matches_description',
    'call_related', 'wanted', 'other',
}
local STOP_SEARCHES <const> = { 'none', 'consent', 'frisk', 'vehicle', 'person_and_vehicle' }
local STOP_RESULTS <const> = { 'no_action', 'warning', 'citation', 'arrest', 'other' }

local function pick(id, title, values, keyPrefix, onPick)
    local options = {}
    for _, value in ipairs(values) do
        options[#options + 1] = {
            title = FredPD.t(keyPrefix .. value),
            onSelect = function() onPick(value) end,
        }
    end

    lib.registerContext({ id = id, title = title, options = options })
    lib.showContext(id)
end

local function recordStop(kind, netId)
    pick('fredpd_stop_reason', FredPD.t('field.stop.reason'), STOP_REASONS, 'stop.reason.', function(reason)
        pick('fredpd_stop_search', FredPD.t('field.stop.search'), STOP_SEARCHES, 'stop.search.', function(search)
            pick('fredpd_stop_result', FredPD.t('field.stop.result'), STOP_RESULTS, 'stop.result.', function(result)
                local recorded = call('stop.create', {
                    kind = kind, reason = reason, search = search, result = result, netId = netId,
                })
                if recorded then core.notify('field.stop.recorded') end
            end)
        end)
    end)
end

--- Picks a fine from the catalogue and issues it. One citation per press.
local function cite(subject)
    local list = call('ordningsbot.tariff.list', {})
    if not list then return end

    local options = {}
    for _, tariff in ipairs(list.tariffs or {}) do
        -- A line the agency wrote itself carries its own label (0036).
        local name = tariff.label or FredPD.t(tariff.labelKey)
        local points = tonumber(tariff.licencePoints) or 0

        options[#options + 1] = {
            title = name,
            description = points > 0 and list.licence
                and FredPD.t('field.cite.amountPoints', { amount = tariff.amount, points = points })
                or FredPD.t('field.cite.amount', { amount = tariff.amount }),
            onSelect = function()
                if not confirm(FredPD.t('field.cite.confirmTitle'),
                    FredPD.t('field.cite.confirm', { tariff = core.plainText(name), who = subject.label }))
                then return end

                local issued = call('ordningsbot.issue', {
                    tariffId = tariff.id,
                    personId = subject.personId,
                    vehicleId = subject.vehicleId,
                })

                if issued then
                    core.notify('ordningsbot.issued', { number = issued.number })
                    if issued.licence then
                        core.notify('field.licence.' .. issued.licence.standing, {
                            points = issued.licence.points, threshold = issued.licence.threshold,
                        })
                    end
                end
            end,
        }
    end

    if #options == 0 then
        core.showError({ err = FredPD.ErrorCode.NOT_FOUND })
        return
    end

    lib.registerContext({ id = 'fredpd_field_cite', title = FredPD.t('field.cite.title'), options = options })
    lib.showContext('fredpd_field_cite')
end

--- The grounds a gripande can rest on (frihet.grund.*), less the placeholder.
local GRUNDER <const> = {
    'pa_bar_garning', 'efterlyst', 'flyktfara', 'kollusionsfara',
    'recidivfara', 'identitet_oklar', 'annan',
}

local function arrest(person)
    local options = {}

    for _, grund in ipairs(GRUNDER) do
        options[#options + 1] = {
            title = FredPD.t('frihet.grund.' .. grund),
            onSelect = function()
                if not confirm(FredPD.t('field.arrest.confirmTitle'),
                    FredPD.t('field.arrest.confirm', { who = person.label, grund = FredPD.t('frihet.grund.' .. grund) }))
                then return end

                local done = call('frihet.gripande', {
                    personId = person.personId,
                    grund = grund,
                    plats = streetHere(),
                })

                if done then core.notify('field.arrest.done', { number = done.number }) end
            end,
        }
    end

    lib.registerContext({ id = 'fredpd_field_arrest', title = FredPD.t('field.arrest.title'), options = options })
    lib.showContext('fredpd_field_arrest')
end

-- -----------------------------------------------------------------------------
-- People
-- -----------------------------------------------------------------------------

--- Arrests somebody who would not show ID, on the ground the law has for
--- exactly that (identitet_oklar). They are registered as an unknown person
--- and identified at booking by their prints.
local function arrestUnidentified(targetId)
    if not confirm(FredPD.t('field.arrest.confirmTitle'), FredPD.t('field.arrest.unidentifiedConfirm')) then return end

    local unknown = call('field.person.unidentified', { targetId = targetId })
    if not unknown then return end

    local done = call('frihet.gripande', {
        personId = unknown.id,
        grund = 'identitet_oklar',
        plats = streetHere(),
    })

    if done then core.notify('field.arrest.done', { number = done.number }) end
end

--- The person's answer to "may I see your ID?" was no. The officer is told,
--- and offered the one lawful next step that does not need a name.
local function refusedId(targetId)
    lib.registerContext({
        id = 'fredpd_field_refused',
        title = FredPD.t('field.person.refusedTitle'),
        options = {
            { title = FredPD.t('field.person.refused'), icon = 'id-card', readOnly = true },
            {
                title = FredPD.t('field.action.arrestUnidentified'), icon = 'handcuffs',
                onSelect = function() arrestUnidentified(targetId) end,
            },
        },
    })
    lib.showContext('fredpd_field_refused')
end

--- Asks the person for their ID (the server asks them; they can refuse) and
--- resolves the record. Nil when there is no answer to act on.
local function resolvePerson(entity)
    local targetId = serverIdOf(entity)
    if not targetId then return nil end

    core.notify('field.person.asking')

    local response = core.call('field.person.resolve', { targetId = targetId })
    if not response.ok then
        if response.err == FredPD.ErrorCode.CONFLICT and type(response.fields) == 'table'
            and response.fields.targetId == 'refused'
        then
            refusedId(targetId)
        else
            core.showError(response)
        end

        return nil
    end

    local person = response.data
    person.targetId = targetId
    person.label = ('%s %s (%s)'):format(person.firstName or '', person.lastName or '', person.personNumber or '?')

    return person
end

--- The other side of "may I see your ID?": the player being asked answers
--- on their own screen, and the answer goes back through a route carrying
--- the one-time token the question came with (server/modules/field/consent.lua).
--- The server treats silence as no, and closes nothing here: it simply stops
--- waiting, so the dialog is closed with it.
RegisterNetEvent('fredpd:showIdRequest', function(request)
    if type(request) ~= 'table' or type(request.token) ~= 'string' then return end

    local callsign = core.plainText(request.callsign or '') or ''
    local open = true

    SetTimeout(20000, function()
        if open then lib.closeAlertDialog() end
    end)

    local shown = lib.alertDialog({
        header = FredPD.t('field.showId.title'),
        content = FredPD.t('field.showId.body', { callsign = callsign }),
        centered = true,
        cancel = true,
        labels = { confirm = FredPD.t('field.showId.show'), cancel = FredPD.t('field.showId.refuse') },
    }) == 'confirm'
    open = false

    core.call('field.person.consent', { token = request.token, shown = shown })
end)

local function openPerson(person)
    FredPD.Client.mdt.open({
        module = 'records', tab = 'query', term = person.personNumber, type = 'person',
    })
end

local function checkId(entity)
    local person = resolvePerson(entity)
    if not person then return end

    local row = queryRecord(person.personNumber, 'person', person.id)

    local options = {}
    if person.registered then
        options[#options + 1] = { title = FredPD.t('field.person.registered'), icon = 'user-plus', readOnly = true }
    end

    -- The licence, when it carries points (0036): a revoked one is the thing
    -- a traffic stop turns on.
    local licence = person.licence
    if licence and licence.points > 0 then
        options[#options + 1] = {
            title = FredPD.t('field.licence.' .. licence.standing, {
                points = licence.points, threshold = licence.threshold,
            }),
            icon = 'id-card',
            iconColor = licence.standing == 'revoked' and '#c62828' or nil,
            readOnly = true,
        }
    end

    hitOptions(row, options)

    local subject = { personId = person.id, label = person.label }
    options[#options + 1] = {
        title = FredPD.t('field.action.cite'), icon = 'file-invoice',
        onSelect = function() cite(subject) end,
    }
    options[#options + 1] = {
        title = FredPD.t('field.action.arrest'), icon = 'handcuffs',
        onSelect = function() arrest({ personId = person.id, label = person.label }) end,
    }
    options[#options + 1] = {
        title = FredPD.t('field.action.open'), icon = 'tablet-screen-button',
        onSelect = function() openPerson(person) end,
    }

    lib.registerContext({ id = 'fredpd_field_person', title = person.label, options = options })
    lib.showContext('fredpd_field_person')
end

--- Why somebody was spoken to, for a field interview card (7.14).
local FI_REASONS <const> = {
    'suspicious_behaviour', 'matches_description', 'known_associate', 'area_check',
    'gang_activity', 'drug_activity', 'other',
}

local function fieldInterview(entity)
    local person = resolvePerson(entity)
    if not person then return end

    pick('fredpd_fi_reason', FredPD.t('field.fi.reason'), FI_REASONS, 'fi.reason.', function(reason)
        local written = call('fi.create', { personId = person.id, reason = reason, here = true })
        if written then core.notify('field.fi.recorded', { name = core.plainText(person.label) }) end
    end)
end

target.addPlayerOptions({
    {
        name = 'fredpd_field_check_id',
        icon = 'fa-solid fa-id-card',
        label = FredPD.t('field.action.checkId'),
        distance = DISTANCE,
        canInteract = function(entity) return serverIdOf(entity) ~= nil end,
        onSelect = function(data) checkId(data and data.entity) end,
    },
    {
        name = 'fredpd_field_interview',
        icon = 'fa-solid fa-clipboard-user',
        label = FredPD.t('field.action.fieldInterview'),
        distance = DISTANCE,
        canInteract = function(entity) return serverIdOf(entity) ~= nil end,
        onSelect = function(data) fieldInterview(data and data.entity) end,
    },
    {
        -- A pedestrian stop names nobody: who they are is what Check ID asks,
        -- with their consent. The stop is the fact that it happened.
        name = 'fredpd_field_stop_person',
        icon = 'fa-solid fa-clipboard-list',
        label = FredPD.t('field.action.recordStop'),
        distance = DISTANCE,
        canInteract = function(entity) return serverIdOf(entity) ~= nil end,
        onSelect = function() recordStop('pedestrian', nil) end,
    },
    {
        name = 'fredpd_field_cite_person',
        icon = 'fa-solid fa-file-invoice',
        label = FredPD.t('field.action.cite'),
        distance = DISTANCE,
        canInteract = function(entity) return serverIdOf(entity) ~= nil end,
        onSelect = function(data)
            local person = resolvePerson(data and data.entity)
            if person then cite({ personId = person.id, label = person.label }) end
        end,
    },
    {
        name = 'fredpd_field_arrest',
        icon = 'fa-solid fa-handcuffs',
        label = FredPD.t('field.action.arrest'),
        distance = DISTANCE,
        canInteract = function(entity) return serverIdOf(entity) ~= nil end,
        onSelect = function(data)
            local person = resolvePerson(data and data.entity)
            if person then arrest({ personId = person.id, label = person.label }) end
        end,
    },
    {
        name = 'fredpd_field_prints',
        icon = 'fa-solid fa-fingerprint',
        label = FredPD.t('field.action.prints'),
        distance = DISTANCE,
        canInteract = function(entity) return serverIdOf(entity) ~= nil end,
        onSelect = function(data)
            local targetId = serverIdOf(data and data.entity)
            if targetId and FredPD.Client.fingerprintScanner then
                FredPD.Client.fingerprintScanner.identify(targetId)
            end
        end,
    },
})

-- -----------------------------------------------------------------------------
-- Vehicles
-- -----------------------------------------------------------------------------

local function runPlate(entity)
    local netId = netIdOf(entity)
    if not netId then return end

    local vehicle = call('field.vehicle.resolve', { netId = netId })
    if not vehicle then return end

    if vehicle.unregistered then
        core.notify('field.vehicle.unregistered', { plate = core.plainText(vehicle.plate) })
        return
    end

    local row = queryRecord(vehicle.plate, 'plate', vehicle.id)

    local options = {}
    if vehicle.registered then
        options[#options + 1] = { title = FredPD.t('field.vehicle.registered'), icon = 'car-side', readOnly = true }
    end

    if row then
        options[#options + 1] = {
            title = FredPD.t('field.vehicle.status', {
                registration = FredPD.t('registry.registration.' .. tostring(row.registrationStatus)),
                insurance = FredPD.t('registry.insurance.' .. tostring(row.insuranceStatus)),
            }),
            icon = 'file-lines',
            readOnly = true,
        }
    end

    hitOptions(row, options)

    local label = vehicle.plate
    options[#options + 1] = {
        title = FredPD.t('field.action.impound'), icon = 'truck-pickup',
        onSelect = function() impound(netId, label) end,
    }
    options[#options + 1] = {
        title = FredPD.t('field.action.citeOwner'), icon = 'file-invoice',
        onSelect = function()
            cite({ vehicleId = vehicle.id, personId = row and row.ownerPersonId or nil, label = label })
        end,
    }
    options[#options + 1] = {
        title = FredPD.t('field.action.open'), icon = 'tablet-screen-button',
        onSelect = function()
            FredPD.Client.mdt.open({ module = 'records', tab = 'query', term = vehicle.plate, type = 'plate' })
        end,
    }

    lib.registerContext({ id = 'fredpd_field_vehicle', title = label, options = options })
    lib.showContext('fredpd_field_vehicle')
end

target.addVehicleOptions({
    {
        name = 'fredpd_field_traffic_stop',
        icon = 'fa-solid fa-car-on',
        label = FredPD.t('field.action.trafficStop'),
        distance = DISTANCE,
        canInteract = function(entity) return netIdOf(entity) ~= nil end,
        onSelect = function(data)
            local netId = netIdOf(data and data.entity)
            if netId and FredPD.Client.status then FredPD.Client.status.selfInitiate('traffic_stop', netId) end
        end,
    },
    {
        name = 'fredpd_field_run_plate',
        icon = 'fa-solid fa-car',
        label = FredPD.t('field.action.runPlate'),
        distance = DISTANCE,
        canInteract = function(entity) return netIdOf(entity) ~= nil end,
        onSelect = function(data) runPlate(data and data.entity) end,
    },
    {
        name = 'fredpd_field_stop_vehicle',
        icon = 'fa-solid fa-clipboard-list',
        label = FredPD.t('field.action.recordStop'),
        distance = DISTANCE,
        canInteract = function(entity) return netIdOf(entity) ~= nil end,
        onSelect = function(data)
            local netId = netIdOf(data and data.entity)
            if netId then recordStop('traffic', netId) end
        end,
    },
    {
        -- Any car, an owner's or an abandoned NPC's: the server records the
        -- impound against whatever plate is on it.
        name = 'fredpd_field_impound',
        icon = 'fa-solid fa-truck-pickup',
        label = FredPD.t('field.action.impound'),
        distance = DISTANCE,
        canInteract = function(entity) return netIdOf(entity) ~= nil end,
        onSelect = function(data)
            local entity = data and data.entity
            local netId = netIdOf(entity)
            if netId then impound(netId, GetVehicleNumberPlateText(entity)) end
        end,
    },
})
