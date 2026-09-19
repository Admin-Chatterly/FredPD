--- Motor pool, client side (spec 7.31).
---
--- Walking up to the attendant ped opens the fleet the *server* says this
--- officer may draw. The menu is built from that answer, so it cannot offer a
--- vehicle the server would then refuse — and asking for one anyway still fails,
--- because the route re-checks (invariant 4).

FredPD = FredPD or {}
FredPD.Client = FredPD.Client or {}

local Garage = {}

--- Where a drawn vehicle appears: in front of the attendant, facing away.
local SPAWN_FORWARD_METRES <const> = 4.0

local function spawnPosition(placement)
    local heading = placement.heading or 0.0
    local radians = math.rad(heading)

    return vec3(
        placement.x - math.sin(radians) * SPAWN_FORWARD_METRES,
        placement.y + math.cos(radians) * SPAWN_FORWARD_METRES,
        placement.z
    ), heading
end

--- Draws a vehicle and puts the officer in it.
local function draw(placement, model)
    local response = FredPD.Client.core.call('garage.draw', {
        placementId = placement.id,
        model = model,
    })

    if not response.ok then
        FredPD.Client.core.showError(response)
        return
    end

    local hash = joaat(response.data.model)
    if not IsModelInCdimage(hash) then
        -- Configured fleet model that this client cannot load. Say so rather
        -- than leaving the officer standing next to nothing.
        FredPD.Client.core.notify('garage.unknownModel')
        return
    end

    lib.requestModel(hash, 10000)

    local position, heading = spawnPosition(placement)
    local vehicle = CreateVehicle(hash, position.x, position.y, position.z, heading, true, false)

    SetVehicleNumberPlateText(vehicle, response.data.plate)
    if response.data.livery then SetVehicleLivery(vehicle, response.data.livery) end

    SetPedIntoVehicle(PlayerPedId(), vehicle, -1)
    SetModelAsNoLongerNeeded(hash)

    FredPD.Client.core.notify('garage.drawn', { plate = response.data.plate })
end

--- Returns the vehicle the officer is sitting in, or the closest one.
local function returnVehicle(placement)
    local ped = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)

    if vehicle == 0 then
        vehicle = GetClosestVehicle(GetEntityCoords(ped), 6.0, 0, 71)
    end

    if vehicle == 0 or not DoesEntityExist(vehicle) then
        FredPD.Client.core.notify('garage.noVehicle')
        return
    end

    local plate = GetVehicleNumberPlateText(vehicle)

    local response = FredPD.Client.core.call('garage.return', {
        placementId = placement.id,
        plate = plate,
    })

    if not response.ok then
        FredPD.Client.core.showError(response)
        return
    end

    -- Delete only after the server has accepted the return, so a refusal never
    -- costs the officer their vehicle.
    SetEntityAsMissionEntity(vehicle, true, true)
    DeleteVehicle(vehicle)

    FredPD.Client.core.notify('garage.returned', { plate = plate })
end

local function openFleet(placement)
    local response = FredPD.Client.core.call('garage.fleet', { placementId = placement.id })

    if not response.ok then
        FredPD.Client.core.showError(response)
        return
    end

    local options = {}

    for index = 1, #response.data.fleet do
        local entry = response.data.fleet[index]
        options[#options + 1] = { value = entry.model, label = FredPD.t(entry.labelKey) }
    end

    options[#options + 1] = { value = '__return', label = FredPD.t('garage.returnVehicle') }

    FredPD.Bridge.ui.showMenu(FredPD.t('garage.title'), options, function(choice)
        if choice == '__return' then
            returnVehicle(placement)
        else
            draw(placement, choice)
        end
    end)
end

--- Registered against the placement kind, so the motor pool appears wherever an
--- administrator put one (spec 3.10) and nowhere else.
FredPD.Client.placements.registerAction('motorpool', openFleet)

FredPD.Client.garage = Garage
