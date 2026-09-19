--- Client-safe configuration. Anything here reaches every player, so it holds
--- no secrets, no permission rules and no forensic truth (invariants 5 and 7).
---
--- Server-only settings -- the Discord bot token above all -- live in
--- `config/server.lua`, which is never listed in `files {}`.

FredPD = FredPD or {}
FredPD.Config = FredPD.Config or {}

--- A convar wins when it is set, otherwise the value in this file does.
---
--- The file is the documented place to configure FredPD; the convars remain so
--- an existing server.cfg keeps working, and so a host that templates its
--- configuration can still inject values without editing a resource file.
---
--- `locale` and `timezone` are read on the client too, where only a *replicated*
--- convar is visible -- so overriding those means `setr`, not `set`. Neither is
--- a secret, so replicating them is safe.
local function setting(convar, fallback)
    local value = GetConvar(convar, '')
    if value == '' then return fallback end
    return value
end

FredPD.Config.shared = {
    --- 'development', 'staging' or 'production'.
    ---
    --- Production refuses to start on an incomplete configuration; development
    --- prints the faults and carries on, so the NUI can be worked on against a
    --- server that is not fully set up.
    env = setting('fredpd:env', 'production'),

    --- Interface language: 'sv' or 'en'.
    locale = setting('fredpd:locale', 'sv'),

    --- Timezone used to render timestamps in the NUI.
    timezone = setting('fredpd:timezone', 'Europe/Stockholm'),

    --- Opens and closes the MDC while seated in an agency vehicle (spec 1.4).
    mdcKeybind = 'F6',

    --- Per-module feature flags that the NUI needs in order to draw its rail.
    --- The server still decides what a session may actually open (invariant 4);
    --- these only keep the UI from advertising a module that is switched off.
    modules = {
        records = true,
        dispatch = false, -- M4
        evidence = false, -- M3
        lab = false, -- M3
        intel = true,
        court = false, -- M6
        personnel = false, -- M6
        admin = true,
    },
}
