--- Client-safe configuration. Anything here reaches every player, so it holds
--- no secrets, no permission rules and no forensic truth (invariants 5 and 7).

FredPD = FredPD or {}
FredPD.Config = FredPD.Config or {}

FredPD.Config.shared = {
    --- Opens and closes the MDC while seated in an agency vehicle (spec 1.4).
    mdcKeybind = 'F6',

    --- Timezone used to render timestamps in the NUI.
    timezone = GetConvar('fredpd:timezone', 'Europe/Stockholm'),

    --- Per-module feature flags that the NUI needs in order to draw its rail.
    --- The server still decides what a session may actually open (invariant 4);
    --- these only keep the UI from advertising a module that is switched off.
    modules = {
        records = true,
        dispatch = false, -- M4
        evidence = false, -- M3
        lab = false, -- M3
        intel = false, -- M5
        court = false, -- M6
        personnel = false, -- M6
        admin = true,
    },
}
