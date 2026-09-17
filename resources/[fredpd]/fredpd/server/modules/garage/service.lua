--- Motor pool logic (spec 7.31).
---
--- Pure: no natives, no database. The fleet filter is the interesting part —
--- it decides which vehicles an officer is shown and allowed to draw, and it is
--- the kind of rule that is easy to get subtly wrong, so it is testable.

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

local Garage = {}

--- Plates are 8 characters in GTA, and the game upper-cases them.
local PLATE_LENGTH <const> = 8
local PLATE_ALPHABET <const> = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'

--- The fleet entries this officer may draw.
---
--- An entry can require an extra permission, a certification, or both. Anything
--- the officer does not satisfy is filtered out rather than shown and refused:
--- a list full of vehicles you cannot take is worse than a short list.
---
--- @param fleet table rows from fpd_fleet
--- @param hasPermission function(permission) -> boolean
--- @param certifications table set of the officer's certifications
--- @return table allowed entries
function Garage.allowedFleet(fleet, hasPermission, certifications)
    local allowed = {}

    for index = 1, #fleet do
        local entry = fleet[index]
        local ok = entry.enabled ~= false

        if ok and entry.permission and not hasPermission(entry.permission) then
            ok = false
        end

        if ok and entry.certification and not certifications[entry.certification] then
            ok = false
        end

        if ok then allowed[#allowed + 1] = entry end
    end

    return allowed
end

--- Finds one fleet entry by model, among those the officer may draw.
---
--- Looking it up in the *filtered* list rather than the full one is what stops a
--- client asking for a model it was never offered: the restriction is applied
--- here, on the server, not by the menu that displayed it (invariant 4).
function Garage.findAllowed(fleet, model, hasPermission, certifications)
    local allowed = Garage.allowedFleet(fleet, hasPermission, certifications)

    for index = 1, #allowed do
        if allowed[index].model == model then return allowed[index] end
    end

    return nil
end

--- Generates an agency plate.
---
--- @param prefix string agency plate prefix, e.g. 'LSPD'
--- @param random function|nil injected for tests
--- @return string
function Garage.generatePlate(prefix, random)
    random = random or math.random

    local plate = (prefix or ''):upper():sub(1, PLATE_LENGTH - 2)
    local remaining = PLATE_LENGTH - #plate

    for _ = 1, remaining do
        local index = random(1, #PLATE_ALPHABET)
        plate = plate .. PLATE_ALPHABET:sub(index, index)
    end

    return plate
end

FredPD.Modules.garage = Garage
