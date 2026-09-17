--- NUI host.
---
--- M0 scope: open and close the interface and hand focus back reliably. Access
--- points, status keys and the camera land in M1.
---
--- The client sends intent only. It never decides what the player may see:
--- the server answers each route with what that session is allowed (invariant 1).

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

--- Development convenience: opening from the console until access points land
--- in M1. It only draws the shell; every piece of data still comes from a route.
RegisterCommand('fredpd', function()
    setOpen(not isOpen)
end, false)

--- Never leave a player stuck with NUI focus and no NUI.
AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() and isOpen then
        SetNuiFocus(false, false)
    end
end)
