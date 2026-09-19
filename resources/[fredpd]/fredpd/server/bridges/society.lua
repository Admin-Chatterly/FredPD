--- Society bridge: esx_society (spec 3.8).
---
--- The agency owns its fleet and its funds, not the officer who happens to be
--- driving. esx_society is where ESX keeps that, so the motor pool (7.31)
--- registers vehicles to the society rather than to a player.

FredPD = FredPD or {}
FredPD.Bridge = FredPD.Bridge or {}

local Society = {}

local RESOURCE <const> = 'esx_society'

local function available()
    return GetResourceState(RESOURCE) == 'started'
end

--- The ESX society name for a FredPD agency.
---
--- Configurable because the society name is a property of the server's job
--- setup, not of FredPD: `lspd` here may be `police` there.
--- @param agencyId string
--- @return string
function Society.nameFor(agencyId)
    local mapping = FredPD.Config.server.societies or {}
    return mapping[agencyId] or ('society_' .. agencyId)
end

--- Registers a drawn vehicle as society property (spec 7.31).
---
--- Returns false when societies are unavailable, so the caller can decide
--- whether that is fatal. For the motor pool it is not: the vehicle still
--- spawns and the draw is still logged against the officer, which is the part
--- that matters for accountability.
--- @param agencyId string
--- @param plate string
--- @param model string
--- @return boolean registered
function Society.registerVehicle(agencyId, plate, model)
    if not available() then return false end

    local ok = pcall(function()
        exports[RESOURCE]:putVehicleInGarage(Society.nameFor(agencyId), {
            plate = plate,
            model = model,
        })
    end)

    return ok
end

--- Removes a vehicle from the society garage when it is drawn out.
function Society.releaseVehicle(agencyId, plate)
    if not available() then return false end

    local ok = pcall(function()
        exports[RESOURCE]:removeVehicleFromGarage(Society.nameFor(agencyId), { plate = plate })
    end)

    return ok
end

--- The society's account balance, for the admin screen.
--- @return number|nil nil when unavailable, which is not the same as zero
function Society.getBalance(agencyId)
    if not available() then return nil end

    local ok, balance = pcall(function()
        return exports[RESOURCE]:getSocietyAccount(Society.nameFor(agencyId))
    end)

    if not ok then return nil end
    return balance
end

function Society.verify()
    if not available() then
        print(('[fredpd] society bridge: %s is not started. Motor pool vehicles will not be registered to the agency.'):format(RESOURCE))
        return false
    end

    return true
end

FredPD.Bridge.society = Society
