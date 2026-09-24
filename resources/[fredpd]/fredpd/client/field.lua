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

--- Picks a fine from the catalogue and issues it. One citation per press.
local function cite(subject)
    local list = call('ordningsbot.tariff.list', {})
    if not list then return end

    local options = {}
    for _, tariff in ipairs(list.tariffs or {}) do
        options[#options + 1] = {
            title = FredPD.t(tariff.labelKey),
            description = FredPD.t('field.cite.amount', { amount = tariff.amount }),
            onSelect = function()
                if not confirm(FredPD.t('field.cite.confirmTitle'),
                    FredPD.t('field.cite.confirm', { tariff = FredPD.t(tariff.labelKey), who = subject.label }))
                then return end

                local issued = call('ordningsbot.issue', {
                    tariffId = tariff.id,
                    personId = subject.personId,
                    vehicleId = subject.vehicleId,
                })

                if issued then core.notify('ordningsbot.issued', { number = issued.number }) end
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
        name = 'fredpd_field_run_plate',
        icon = 'fa-solid fa-car',
        label = FredPD.t('field.action.runPlate'),
        distance = DISTANCE,
        canInteract = function(entity) return netIdOf(entity) ~= nil end,
        onSelect = function(data) runPlate(data and data.entity) end,
    },
})
