--- Status from the keyboard (spec 7.16): the things an officer does to the
--- board a dozen times a shift, without opening the MDT.
---
--- Every command is a key the officer binds themselves under Settings ->
--- Key Bindings -> FiveM; none ships with a default, for the reason the panic
--- key does not (client/cad.lua): a key FredPD picked is a key some other
--- resource already owns. Each one is an ordinary route the server checks.

local core = FredPD.Client.core

--- The street at the officer's feet, as a label for a call they raise.
local function streetHere()
    local at = GetEntityCoords(PlayerPedId())
    local street, crossing = GetStreetNameAtCoord(at.x, at.y, at.z)
    local name = street and street ~= 0 and GetStreetNameFromHashKey(street) or nil
    local cross = crossing and crossing ~= 0 and GetStreetNameFromHashKey(crossing) or nil

    if not name or name == '' then return nil end
    if cross and cross ~= '' then name = name .. ' / ' .. cross end

    return name:sub(1, 96)
end

local function run(route, data, doneKey, params)
    local response = core.call(route, data or {})
    if not response.ok then
        core.showError(response)
        return nil
    end

    if doneKey then core.notify(doneKey, params and params(response.data) or nil) end
    return response.data
end

local function status(value)
    run('unit.progress', { status = value }, 'status.done', function()
        return { status = FredPD.t('cad.unitStatus.' .. value) }
    end)
end

--- Raises a call the officer is standing at. `netId` names the car of a
--- traffic stop, whose plate the server reads for itself.
local function selfInitiate(callType, netId)
    run('call.self_initiate', { type = callType, netId = netId, streetLabel = streetHere() },
        'status.selfInitiated', function(data) return { number = data.callNumber } end)
end

local SELF_TYPES <const> = {
    'traffic_stop', 'suspicious', 'disturbance', 'drugs', 'weapons', 'welfare_check', 'other',
}

local function selfInitiateMenu()
    local options = {}
    for _, callType in ipairs(SELF_TYPES) do
        options[#options + 1] = {
            title = FredPD.t('cad.callType.' .. callType),
            onSelect = function() selfInitiate(callType) end,
        }
    end

    lib.registerContext({ id = 'fredpd_self_initiate', title = FredPD.t('status.selfInitiateTitle'), options = options })
    lib.showContext('fredpd_self_initiate')
end

local DISPOSITIONS <const> = {
    'handled_on_scene', 'warning_given', 'citation_issued', 'arrest_made', 'report_taken',
    'assistance_rendered', 'gone_on_arrival', 'unable_to_locate', 'unfounded', 'referred',
}

local function clearMenu()
    local options = {}
    for _, disposition in ipairs(DISPOSITIONS) do
        options[#options + 1] = {
            title = FredPD.t('cad.disposition.' .. disposition),
            onSelect = function()
                run('call.clear_mine', { disposition = disposition }, 'status.cleared')
            end,
        }
    end

    lib.registerContext({ id = 'fredpd_clear_mine', title = FredPD.t('status.clearTitle'), options = options })
    lib.showContext('fredpd_clear_mine')
end

local COMMANDS <const> = {
    { name = 'fredpd_enroute', label = 'status.key.enRoute', action = function() status('en_route') end },
    { name = 'fredpd_onscene', label = 'status.key.onScene', action = function() status('on_scene') end },
    { name = 'fredpd_available', label = 'status.key.available', action = function() status('available') end },
    {
        name = 'fredpd_attach', label = 'status.key.attach',
        action = function()
            run('call.attach_nearest', {}, 'status.attached', function(data) return { number = data.callNumber } end)
        end,
    },
    { name = 'fredpd_selfinit', label = 'status.key.selfInitiate', action = selfInitiateMenu },
    { name = 'fredpd_clear', label = 'status.key.clear', action = clearMenu },
}

for _, command in ipairs(COMMANDS) do
    RegisterCommand(command.name, command.action, false)
    RegisterKeyMapping(command.name, FredPD.t(command.label), 'keyboard', '')
end

FredPD.Client.status = { selfInitiate = selfInitiate }
