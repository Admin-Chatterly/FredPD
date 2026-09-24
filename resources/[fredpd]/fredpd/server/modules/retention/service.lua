--- Retention (spec 13.3, ADR-021): the pure part -- which sweeps run, with
--- how many days, and when.
---
--- No natives, no database (`spec/retention_spec.lua`).

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

local Retention = {}

--- What each sweep keeps, in days, when config says nothing, and the
--- fewest days config may set. A floor, because a typo that turns 365 into
--- 3 would otherwise empty a table overnight, and nothing brings it back.
Retention.DEFAULTS = {
    queryLog = { days = 365, floor = 30 },
    alprReads = { days = 30, floor = 7 },
    staleDrafts = { days = 180, floor = 30 },
    surveillanceSessions = { days = 730, floor = 90 },
    stops = { days = 730, floor = 90 },
    abandonedUploads = { days = 1, floor = 1 },
}

--- The order the sweeps run and are reported in.
Retention.ORDER = {
    'lapsedLookouts', 'queryLog', 'alprReads', 'staleDrafts', 'surveillanceSessions', 'stops', 'abandonedUploads',
}

--- The days each sweep keeps, from config, never below its floor. A sweep
--- set to `false` is off.
---
--- @param configured table|nil `{ queryLog = 365, alprReads = false, ... }`
--- @return table name -> days | false
function Retention.plan(configured)
    local plan = {}
    configured = type(configured) == 'table' and configured or {}

    for name, default in pairs(Retention.DEFAULTS) do
        local value = configured[name]

        if value == false then
            plan[name] = false
        else
            local days = tonumber(value) or default.days
            plan[name] = math.max(default.floor, math.floor(days))
        end
    end

    -- Resolving a lookout whose window has run out is not a retention
    -- period, just housekeeping 7.13 asks for; it runs unless turned off.
    plan.lapsedLookouts = configured.lapsedLookouts ~= false

    return plan
end

--- Is a run due? The first one waits `startDelay` seconds after start, so a
--- restart is not also a sweep; after that, every `intervalMinutes`.
function Retention.due(lastRun, startedAt, now, intervalMinutes, startDelay)
    if not lastRun then return now - startedAt >= (startDelay or 600) end
    return now - lastRun >= math.max(15, tonumber(intervalMinutes) or 360) * 60
end

FredPD.Modules.retention = Retention

return Retention
