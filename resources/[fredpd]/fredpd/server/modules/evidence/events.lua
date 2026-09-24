--- The automatic lab (spec 8.7): keep the roles, fill the gaps.
---
--- A lab analyst doing the work at the bench is the design, and nothing here
--- takes it from one who is signed on. What it fixes is the evening nobody
--- plays the analyst: requests used to sit queued until somebody did, and the
--- case they were for stalled with them. So, once a minute:
---
---   * with no session holding `lab.analysis.perform` in the agency, a request
---     waiting longer than `lab.autoStartAfterSeconds` is started by the lab
---     itself (`system`), on the same turnaround an analyst's would get;
---   * an analysis whose clock has run out is finished -- at once if the lab
---     started it, `lab.autoCompleteGraceSeconds` later if an analyst did and
---     has not written it up.
---
--- Finishing goes through `finishAnalysis`, the same code the analyst's route
--- runs, so the result, the index, the candidates and the notices are
--- identical. Each step is audited as the automatic lab's.

local repo = FredPD.Repo.evidence
local service = FredPD.Modules.evidence

local SYSTEM <const> = 'system'
local INTERVAL_MS <const> = 60 * 1000
local BATCH <const> = 10

local function config()
    return FredPD.Config.server.lab or {}
end

local function analystOnline(agencyId)
    for _, session in pairs(FredPD.Core.session.all()) do
        if session.agencyId == agencyId
            and FredPD.Core.perms.satisfies(session.permissions, 'lab.analysis.perform')
        then
            return true
        end
    end

    return false
end

local function audit(action, agencyId, id, analysis)
    FredPD.Core.audit.write({
        action = action,
        agencyId = agencyId,
        subjectType = 'lab_analysis',
        subjectId = tostring(id),
        detail = { analysis = analysis, automatic = true },
    })
end

local function pass()
    local settings = config()
    if settings.auto == false then return end

    local agencyId = FredPD.Config.server.agency.id

    if not analystOnline(agencyId) then
        for _, row in ipairs(repo.autoStartable(agencyId, tonumber(settings.autoStartAfterSeconds) or 120, BATCH)) do
            local seconds = service.turnaroundSeconds(row.analysis, row.priority, settings)

            if repo.startAnalysis(agencyId, row.id, SYSTEM, seconds) > 0 then
                audit('lab.analysis.started', agencyId, row.id, row.analysis)
            end
        end
    end

    for _, row in ipairs(repo.autoCompletable(agencyId, tonumber(settings.autoCompleteGraceSeconds) or 900, BATCH)) do
        local result = FredPD.Evidence.finishAnalysis(agencyId, SYSTEM, row.id, nil)

        if type(result) == 'table' and not result.__err then
            audit('lab.analysis.completed', agencyId, row.id, row.analysis)
        end
    end
end

CreateThread(function()
    while true do
        Wait(INTERVAL_MS)

        local ok, err = pcall(pass)
        if not ok then print(('[fredpd] automatic lab pass failed: %s'):format(tostring(err))) end
    end
end)
