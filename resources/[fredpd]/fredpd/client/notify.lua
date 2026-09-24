--- The notification relay (spec 3.6): the server's `fredpd:notify` pushes
--- turned into on-screen toasts, so an officer learns they were dispatched,
--- that a lab result is in or that a decision waits on them without having the
--- MDT open.
---
--- The payload is a locale key and its parameters, never text (invariant 6)
--- and never a record: the toast says that something happened, and the MDT is
--- where the officer reads what. A key that is not one is dropped rather than
--- printed, the same rule `t()` misses follow everywhere else.

local TYPES <const> = { inform = true, success = true, warning = true, error = true }

--- ox_lib renders a notification's text as markdown. A parameter is data --
--- a callsign, a street, a name -- and must never become a link or an image
--- (an image URL is an IP grab, spec 11.1), so every markdown character in
--- one is escaped before it is placed into the sentence.
local function plain(params)
    if type(params) ~= 'table' then return nil end

    local out = {}
    for name, value in pairs(params) do
        if type(value) == 'string' then
            out[name] = value:gsub('[%[%]%(%)!%*_`#<>\\~|]', '\\%0')
        elseif type(value) == 'number' then
            out[name] = value
        end
    end

    return out
end

RegisterNetEvent('fredpd:notify', function(payload)
    if type(payload) ~= 'table' or type(payload.key) ~= 'string' then return end
    if not payload.key:match('^[%w_]+[%w_%.]*$') then return end

    local description = FredPD.t(payload.key, plain(payload.params))
    if description == payload.key then return end

    lib.notify({
        title = FredPD.t('app.name'),
        description = description,
        type = TYPES[payload.type] and payload.type or 'inform',
        duration = 8000,
    })

    local waypoint = payload.waypoint
    if type(waypoint) == 'table' and tonumber(waypoint.x) and tonumber(waypoint.y) then
        SetNewWaypoint(tonumber(waypoint.x) + 0.0, tonumber(waypoint.y) + 0.0)
    end
end)
