--- Civilian garage bridge: jg-advancedgarages (spec 3.8).
---
--- The only bridge in this resource that listens rather than calls: FredPD
--- has no reason to ask jg-advancedgarages for anything, but it does want to
--- know when a flagged plate is put away or brought back out, and the two
--- client events the resource already fires on store and take-out carry
--- everything needed for that -- the vehicle's own plate.
---
--- So there is nothing to check before relaying one. `garage.plateEvent` in
--- the core is the one place that decides whether a plate is a BOLO and
--- whether dispatch hears about it (invariant 1) -- this file only names the
--- plate and which of the two happened, the same way a forensic sensor names
--- a key and nothing about what it might mean (8.3.1).
---
--- Registered unconditionally rather than behind a `GetResourceState` check:
--- an event nobody ever fires costs nothing to listen for, and client script
--- load order across resources is not something FredPD can rely on to check
--- correctly at boot the way a server-side bridge can.

FredPD = FredPD or {}
FredPD.Client = FredPD.Client or {}

local RESOURCE <const> = 'jg-advancedgarages'

--- @param action string 'store' | 'takeout'
local function report(action)
    return function(_vehicle, vehicleDbData)
        local plate = type(vehicleDbData) == 'table' and vehicleDbData.plate

        if type(plate) == 'string' and plate ~= '' then
            FredPD.Client.core.call('garage.plateEvent', { plate = plate, action = action })
        end
    end
end

RegisterNetEvent(RESOURCE .. ':client:InsertVehicle:config', report('store'))
RegisterNetEvent(RESOURCE .. ':client:TakeOutVehicle:config', report('takeout'))
