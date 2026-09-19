--- Test helper for busted.
---
--- Loads the pure modules under test without a FiveM runtime. Only files that
--- contain no natives can be loaded this way, which is exactly the rule spec 3.4
--- sets for `service.lua` -- so if a load fails here, a native has crept into a
--- file that is supposed to be testable.

local helper = {}

--- Resets the global namespace and loads the named files, in order.
--- @param files table paths relative to the resource root, without `.lua`
function helper.load(files)
    _G.FredPD = {}

    for index = 1, #files do
        local chunk = assert(loadfile(('resources/[fredpd]/fredpd/%s.lua'):format(files[index])))
        chunk()
    end

    return _G.FredPD
end

--- Pass as an override value to unset a field.
---
--- `{ callsign = nil }` cannot work: `pairs` never visits a nil value, so the
--- override is silently ignored and the test asserts against the default. This
--- sentinel makes "remove this field" something the helper can actually see.
helper.NONE = setmetatable({}, { __tostring = function() return 'helper.NONE' end })

--- A session, with only the fields the pure code actually reads.
function helper.session(overrides)
    local session = {
        src = 1,
        discordId = '100000000000000001',
        officerId = 1,
        agencyId = 'lspd',
        callsign = '12-40',
        name = 'A. Lindqvist',
        permissions = {},
    }

    for key, value in pairs(overrides or {}) do
        session[key] = value ~= helper.NONE and value or nil
    end

    return session
end

return helper
