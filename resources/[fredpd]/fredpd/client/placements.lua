--- Placement rendering and interaction (spec 3.10, ADR-006).
---
--- Draws whatever the server says exists: spawns peds, binds props, and shows
--- the prompt when a player is close enough. Pressing the key calls a route,
--- which checks the permission and re-verifies the distance server-side.
---
--- The client never decides who may use a placement. It is drawing a door, not
--- deciding who holds the key (invariant 4).

FredPD = FredPD or {}
FredPD.Client = FredPD.Client or {}

local Placements = {}

--- How far away a placement can be before the check thread stops looking at it
--- closely. Keeps the per-frame cost near zero when nobody is near a station.
local NEAR_METRES <const> = 20.0
local INTERACT_KEY <const> = 38 -- E

local placements = {}
local spawnedPeds = {}
local active = nil

--- What each placement kind does when interacted with.
---
--- A kind with no action here shows no prompt: an unconfigured entrance is
--- inert rather than broken.
local actions = {}

function Placements.registerAction(kind, handler)
    actions[kind] = handler
end

-- -----------------------------------------------------------------------------
-- Entities
-- -----------------------------------------------------------------------------

local function removePeds()
    for _, ped in pairs(spawnedPeds) do
        if DoesEntityExist(ped) then DeleteEntity(ped) end
    end

    spawnedPeds = {}
end

--- Spawns the peds for `ped` placements (the motor pool attendant, and anything
--- else configured that way).
local function spawnPeds()
    removePeds()

    for _, placement in pairs(placements) do
        if placement.interaction == 'ped' and placement.model then
            local model = joaat(placement.model)

            if IsModelInCdimage(model) then
                lib.requestModel(model, 10000)

                local ped = CreatePed(4, model, placement.x, placement.y, placement.z - 1.0,
                    placement.heading or 0.0, false, true)

                SetEntityInvincible(ped, true)
                FreezeEntityPosition(ped, true)
                SetBlockingOfNonTemporaryEvents(ped, true)
                SetModelAsNoLongerNeeded(model)

                spawnedPeds[placement.id] = ped
            else
                -- A bad model in configuration should say so, not fail silently
                -- and leave an invisible entrance.
                print(('[fredpd] placement %d: unknown ped model "%s"'):format(placement.id, placement.model))
            end
        end
    end
end

-- -----------------------------------------------------------------------------
-- Proximity and prompt
-- -----------------------------------------------------------------------------

--- The closest placement within its own radius, or nil.
local function closestTo(position)
    local best, bestDistance = nil, math.huge

    for _, placement in pairs(placements) do
        if actions[placement.kind] then
            local distance = #(position - vec3(placement.x, placement.y, placement.z))

            if distance <= (placement.radius or 1.5) and distance < bestDistance then
                best, bestDistance = placement, distance
            end
        end
    end

    return best
end

--- True when any placement is within `NEAR_METRES`, so the fine-grained loop
--- only runs where there is something to interact with.
local function anythingNear(position)
    for _, placement in pairs(placements) do
        if #(position - vec3(placement.x, placement.y, placement.z)) <= NEAR_METRES then
            return true
        end
    end

    return false
end

local function setActive(placement)
    if active and active.id == (placement and placement.id) then return end

    if active then FredPD.Bridge.ui.hidePrompt() end
    active = placement

    if placement then
        -- The prompt text is a locale key on the placement, never a literal
        -- string chosen by whoever configured it (invariant 6).
        FredPD.Bridge.ui.showPrompt(FredPD.t(placement.labelKey or ('placement.' .. placement.kind)))
    end
end

CreateThread(function()
    while true do
        local sleep = 1000
        local position = GetEntityCoords(PlayerPedId())

        if next(placements) and anythingNear(position) then
            sleep = 0
            local found = closestTo(position)
            setActive(found)

            if found and IsControlJustReleased(0, INTERACT_KEY) then
                local action = actions[found.kind]
                if action then action(found) end
            end
        elseif active then
            setActive(nil)
        end

        Wait(sleep)
    end
end)

-- -----------------------------------------------------------------------------
-- Server feed
-- -----------------------------------------------------------------------------

--- Two feeds, drawn as one: the officer's own (pushed with the session) and
--- the public desks every player is told about (7.29, pulled). Neither
--- replaces the other, so an officer who signs off still sees the desk.
local pushed, public = {}, {}

local function rebuild()
    placements = {}
    for id, placement in pairs(public) do placements[id] = placement end
    for id, placement in pairs(pushed) do placements[id] = placement end

    setActive(nil)
    spawnPeds()
end

RegisterNetEvent('fredpd:placements', function(payload)
    pushed = {}

    for index = 1, #(payload.placements or {}) do
        local placement = payload.placements[index]
        pushed[placement.id] = placement
    end

    rebuild()
end)

--- The public desks, from `placements.public`.
function Placements.setPublic(list)
    public = {}
    for index = 1, #(list or {}) do public[list[index].id] = list[index] end
    rebuild()
end

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        removePeds()
        FredPD.Bridge.ui.hidePrompt()
    end
end)

--- Forgets which placement is active, so the nearest one's prompt is shown
--- again on the next tick: for a screen that took the prompt down (a camera
--- view) and is done with it.
function Placements.refresh()
    setActive(nil)
end

--- The placements this client knows about, for the editor.
function Placements.all()
    return placements
end

FredPD.Client.placements = Placements
