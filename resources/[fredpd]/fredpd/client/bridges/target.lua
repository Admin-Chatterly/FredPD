--- The targeting bridge (spec 3.8): the only place core FredPD names
--- ox_target. `fredpd_forensics` has its own, for its own options.
---
--- A server without ox_target still runs FredPD: the options are simply not
--- offered, and the console says why once, at start.

FredPD = FredPD or {}
FredPD.Client = FredPD.Client or {}

local RESOURCE <const> = 'ox_target'

local Target = {}

local players, vehicles = {}, {}

local function available()
    return GetResourceState(RESOURCE) == 'started'
end

--- @param options table ox_target option list, each with a unique `name`
function Target.addPlayerOptions(options)
    if not available() then return false end

    exports[RESOURCE]:addGlobalPlayer(options)
    for index = 1, #options do players[#players + 1] = options[index].name end

    return true
end

--- @param options table ox_target option list, each with a unique `name`
function Target.addVehicleOptions(options)
    if not available() then return false end

    exports[RESOURCE]:addGlobalVehicle(options)
    for index = 1, #options do vehicles[#vehicles + 1] = options[index].name end

    return true
end

-- Never leave options behind on a restart: ox_target keeps them keyed by
-- name, and a reload would leave prompts that call into a dead Lua state.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() or not available() then return end

    if #players > 0 then exports[RESOURCE]:removeGlobalPlayer(players) end
    if #vehicles > 0 then exports[RESOURCE]:removeGlobalVehicle(vehicles) end
end)

CreateThread(function()
    Wait(1000)

    if not available() then
        print('[fredpd] ox_target is not started: the field actions on people and vehicles are off.')
    end
end)

FredPD.Client.target = Target
