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
        'CreatePed',
        'CreateVehicle',
        'DeleteEntity',
        'DeleteVehicle',
        'FreezeEntityPosition',
        'GetClosestVehicle',
        'GetEntityForwardVector',
        'GetGameplayCamCoord',
        'GetShapeTestResult',
        'GetVehicleNumberPlateText',
        'IsControlJustReleased',
        'IsModelInCdimage',
        'IsPedInAnyVehicle',
        'PlayerPedId',
        'SetBlockingOfNonTemporaryEvents',
        'SetEntityAsMissionEntity',
        'SetEntityInvincible',
        'SetModelAsNoLongerNeeded',
        'SetPedIntoVehicle',
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
