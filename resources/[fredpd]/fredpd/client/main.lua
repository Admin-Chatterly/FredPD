--- NUI host.
---
--- The client sends intent only. It never decides what the player may see: the
--- server answers each route with what that session is allowed (invariant 1).

local isOpen = false

--- Shows or hides the NUI and moves keyboard and mouse focus with it.
--- @param open boolean
local function setOpen(open)
    if open == isOpen then return end

    isOpen = open
    SetNuiFocus(open, open)
    SendNUIMessage({ type = open and 'fredpd:open' or 'fredpd:close' })
end

--- The NUI asks to be closed (Escape, or the title bar) rather than closing
--- itself, so focus and state always change in one place.
RegisterNUICallback('fredpd:close', function(_, cb)
    setOpen(false)
    cb({ ok = true })
end)

--- The NUI calls a route. Everything it asks for goes through the route layer,
--- with the session, permission and context checked server-side (invariant 3).
RegisterNUICallback('fredpd:route', function(data, cb)
    if type(data) ~= 'table' or type(data.route) ~= 'string' then
        cb({ ok = false, err = FredPD.ErrorCode.INVALID })
        return
    end

    cb(FredPD.Client.core.call(data.route, data.body))
end)

AddEventHandler('fredpd:toggleInterface', function()
    setOpen(not isOpen)
end)

--- Opening a terminal is the same action wherever it is placed, so every
--- terminal kind maps to it (spec 3.10). What the officer can then *do* inside
--- differs by permission, which the server decides.
for _, kind in ipairs({
    'station_terminal',
    'property_terminal',
    'lab_terminal',
    'booking_terminal',
    'dispatch_console',
    'courthouse_terminal',
}) do
    FredPD.Client.placements.registerAction(kind, function()
        setOpen(true)
    end)
end

--- Permissions changed while the player was connected: a role was added or
--- removed, or an administrator edited the role map. The shell redraws its rail
--- from what the server now allows (spec 4.2).
RegisterNetEvent('fredpd:permissions', function(payload)
    SendNUIMessage({ type = 'fredpd:permissions', modules = payload.modules })
end)

--- Ask for world geometry once the session exists on the server.
AddEventHandler('playerSpawned', function()
    TriggerServerEvent('fredpd:requestPlacements')
end)

CreateThread(function()
    -- Covers a resource restart while players are already in the world, where
    -- playerSpawned has long since fired.
    Wait(2000)
    TriggerServerEvent('fredpd:requestPlacements')
end)

--- Never leave a player stuck with NUI focus and no NUI.
AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() and isOpen then
        SetNuiFocus(false, false)
    end
end)
