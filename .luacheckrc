-- luacheck configuration for the FiveM resources.
-- Invariant: no accidental globals (spec 15).

std = 'lua54'
max_line_length = 140

-- Globals we may read but never assign. Anything not listed here and not in
-- `globals` below is a typo or an accidental global, which is the whole point
-- of running this.
read_globals = {
    -- FiveM natives and server API
    'AddEventHandler',
    'Citizen',
    'CreateThread',
    'GetCurrentResourceName',
    'GetConvar',
    'GetConvarInt',
    'GetGameTimer',
    'GetPlayerIdentifierByType',
    'GetPlayerName',
    'GetPlayers',
    'GetPlayerPed',
    'GetResourceMetadata',
    'GetResourceState',
    'LoadResourceFile',
    'PerformHttpRequest',
    'promise',
    'RegisterCommand',
    'RegisterNetEvent',
    'RemoveEventHandler',
    'SaveResourceFile',
    'SetHttpHandler',
    'SetTimeout',
    'TriggerClientEvent',
    'TriggerEvent',
    'TriggerServerEvent',
    'Wait',
    'source',

    -- NUI (client only)
    'SendNUIMessage',
    'SetNuiFocus',
    'RegisterNUICallback',

    -- Entities and world, used on both sides
    'DoesEntityExist',
    'GetEntityCoords',
    'GetEntityHeading',
    'GetEntityModel',
    'GetVehicleClass',
    'GetVehiclePedIsIn',
    'joaat',
    'vec3',
    -- Server side too: `weaponDamageEvent` and every sensor observation names
    -- entities by network id, and resolving one is how the server checks that
    -- the entity exists and is where the reporter says it is (spec 8.3.2).
    'NetworkGetEntityFromNetworkId',

    -- Ecosystem
    'exports',
    'lib',
    'cache',
    'MySQL',
    'json',
}

-- Each resource defines and assigns to its own namespace during boot, so these
-- are writable. Listing a name here *and* in read_globals would make it
-- read-only and flag every assignment.
globals = {
    'FredPD',
    'FredPDForensics',
    'FredPDSurveillance',
}

exclude_files = {
    'node_modules',
    'vendor',
    'web',
}

-- A manifest is a declarative DSL, not a script: every directive looks like an
-- undefined global to luacheck unless it is declared.
files['**/fxmanifest.lua'] = {
    read_globals = {
        'fx_version',
        'game',
        'games',
        'lua54',
        'use_experimental_fxv2_oal',
        'name',
        'description',
        'author',
        'version',
        'repository',
        'dependency',
        'dependencies',
        'provide',
        'shared_script',
        'shared_scripts',
        'server_script',
        'server_scripts',
        'client_script',
        'client_scripts',
        'files',
        'file',
        'ui_page',
        'data_file',
        'this_is_a_map',
        'server_only',
        'export',
        'exports',
        'server_export',
        'server_exports',
        'escrow_ignore',
        'dependencies_check',
    },
}

-- Natives that only exist on the client.
files['**/client/**/*.lua'] = {
    read_globals = {
        -- Drawing a number over an evidence marker (spec 8.4). The text
        -- commands come as a set: an origin, the style, the string, the draw.
        'AddTextComponentSubstringPlayerName',
        'BeginTextCommandDisplayText',
        'ClearDrawOrigin',
        'CreateObject',
        'CreatePed',
        'CreateVehicle',
        'DeleteEntity',
        'DeleteVehicle',
        -- Evidence with no prop configured for its type is drawn as a marker by
        -- fredpd_forensics rather than guessed at as a model (spec 8.1.6).
        'DrawMarker',
        'EndTextCommandDisplayText',
        'FreezeEntityPosition',
        'GetClosestVehicle',
        'GetEntityForwardVector',
        'GetGameplayCamCoord',
        -- Which seat a ped is in, asked of the vehicle rather than of ox_lib's
        -- cache: the forensics sensors need the seat and the vehicle in the
        -- same breath, and the order the two cache keys update in is not part
        -- of ox_lib's contract (spec 8.2, prints per door).
        'GetPedInVehicleSeat',
        'GetShapeTestResult',
        'GetVehicleNumberPlateText',
        'IsControlJustReleased',
        'IsModelInCdimage',
        'IsPedArmed',
        'IsPedInAnyVehicle',
        -- The one piece of player state the game exposes only as a question and
        -- never as an event, which is why the reload sensor is the only loop in
        -- fredpd_forensics (spec 8.2, magazines).
        'IsPedReloading',
        -- A sensor names an entity by network id and by nothing else, so the
        -- server can resolve it, check it exists and check the player is within
        -- reach of it (spec 8.3.2). Both halves are client-side here.
        'NetworkGetEntityIsNetworked',
        'NetworkGetNetworkIdFromEntity',
        'PlayerPedId',
        -- The forensic kit opens from a key the player binds themselves; the
        -- resource ships no default binding (spec 8.4).
        'RegisterKeyMapping',
        'SetBlockingOfNonTemporaryEvents',
        'SetDrawOrigin',
        'SetEntityAsMissionEntity',
        -- A streamed evidence prop is scenery: it must not be something a
        -- player can trip over or shove down the street.
        'SetEntityCollision',
        'SetEntityInvincible',
        'SetModelAsNoLongerNeeded',
        'SetPedIntoVehicle',
        'SetTextCentre',
        'SetTextColour',
        'SetTextFont',
        'SetTextOutline',
        'SetTextProportional',
        'SetTextScale',
        'SetVehicleLivery',
        'SetVehicleNumberPlateText',
        'StartShapeTestRay',
        'ESX',
    },
}

-- Generated code is machine-formatted; long table literals there are expected.
files['**/shared/generated/*.lua'] = {
    max_line_length = false,
}

files['**/*_spec.lua'] = {
    std = '+busted',
}
