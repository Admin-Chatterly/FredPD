--- The retention sweep (spec 13.3, ADR-021), run inside FXServer.
---
--- It used to be the gateway scheduler's job, and the gateway is off by
--- default (ADR-010): an install that never deployed Node never swept
--- anything, and its query log and plate reads grew for ever. The sweep
--- lives here now, on a timer; the gateway is asked only to delete the files
--- of abandoned uploads, when it is on.
---
--- One audit row per run names what every sweep did (13.3: "writes a summary
--- to the audit log and never touches the audit log itself").

local service = FredPD.Modules.retention
local repo = FredPD.Repo.retention

local Events = {}

local startedAt = os.time()
local lastRun = nil
local running = false

local function config()
    return FredPD.Config.server.retention or {}
end

--- Uploads nobody finished: the files first, then the ledger rows. A row
--- whose file could not be removed is kept for the next run rather than
--- forgotten with its file still there -- and with the gateway off (turned
--- off, or its secret missing after a restart) nothing is forgotten at all:
--- the files may still be on its disk, and a pending row costs nothing.
local function abandonedUploads(days)
    local gateway = FredPD.Bridge.gateway.service
    if not gateway.isEnabled() then return 0 end

    local rows = repo.abandonedUploads(days, 200)
    if #rows == 0 then return 0 end

    local refs = {}
    for index, row in ipairs(rows) do refs[index] = row.mediaRef end

    if not gateway.deleteMedia(refs) then return 0 end

    local forgotten = 0
    for _, row in ipairs(rows) do forgotten = forgotten + (repo.forgetUpload(row.mediaRef) or 0) end

    return forgotten
end

--- The configured days, with `cad.alprRetentionDays` (7.18's own setting,
--- older than this sweep) standing in when `retention.days` names no
--- window for plate reads.
local function configuredDays()
    local days = {}
    for name, value in pairs(config().days or {}) do days[name] = value end

    if days.alprReads == nil then
        local cad = FredPD.Config.server.cad or {}
        days.alprReads = cad.alprRetentionDays
    end

    return days
end

--- One run of every sweep the plan leaves on, in order.
--- @return table name -> rows affected
function Events.run()
    local plan = service.plan(configuredDays())
    local results = {}
    local failed = false

    for _, name in ipairs(service.ORDER) do
        local days = plan[name]

        if days ~= false and days ~= nil then
            local ok, affected = pcall(function()
                if name == 'lapsedLookouts' then return repo.lapsedLookouts() end
                if name == 'abandonedUploads' then return abandonedUploads(days) end
                return repo[name](days)
            end)

            results[name] = ok and (affected or 0) or 'failed'
            if not ok then
                failed = true
                print(('[fredpd] retention: %s failed: %s'):format(name, tostring(affected)))
            end
        end
    end

    FredPD.Core.audit.write({
        action = 'retention.swept',
        subjectType = 'retention',
        -- A run with a failed sweep is findable by outcome, not only by
        -- reading every row's detail.
        outcome = failed and 'error' or 'ok',
        detail = results,
    })

    return results
end

CreateThread(function()
    while true do
        Wait(60 * 1000)

        local cfg = config()
        if cfg.enabled ~= false and not running
            and service.due(lastRun, startedAt, os.time(), cfg.intervalMinutes, cfg.startDelaySeconds)
        then
            running = true
            lastRun = os.time()

            local ok, err = pcall(Events.run)
            if not ok then print(('[fredpd] retention run failed: %s'):format(tostring(err))) end

            running = false
        end
    end
end)

FredPD.Modules.retentionRun = Events
